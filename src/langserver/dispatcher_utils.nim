import std/[options, tables, algorithm, os, sequtils, sugar]
import chronos
import chronicles
import ../nim_tools/nimsuggest/[suggestapi, nimsuggest_types, nimsuggest]
import ../nim_tools/nimcheck/nimcheck
import ../nim_tools/compiler/nim_compiler
import ../protocol/[enums, types]
import ./[
  checking, configurations,
  constants, diagnostics, formatting, 
]
import ./[langserver_types, nimsuggest_types, query_types]

proc isKnownByNimsuggest*(nimsuggest: Nimsuggest, filePath: string): Future[bool] {.async.} =
  # Checks response[0].forth == "true" — the boolean result comes back as a string in the forth field of a Suggest object.
  let response: seq[Suggest] = await nimsuggest.known(filePath)
  if response.len == 0:
    return false
  else:
    return response[0].forth == "true"

proc checkNimsuggestSlotKnowsURI(slot: NimsuggestSlot, uri: string): Future[Option[NimsuggestSlot]] {.async.} =
  case slot.state
  of SlotState.SPAWNING:
    try:
      discard await slot.ns.get()
    except CatchableError:
      return none(NimsuggestSlot)
  of SlotState.READY:
    discard
  else:
    return none(NimsuggestSlot)

  let ns = await slot.ns.get() 
  if await ns.isKnownByNimsuggest(uri.uriToPath):
    return some(slot)

  return none(NimsuggestSlot)

proc isKnownByANimsuggestSlot*(pool: NimsuggestPool, uri: string): Option[NimsuggestSlot] {.async.} =
  var futures: seq[
    tuple[projectFile: string, future: Future[Option[NimsuggestSlot]]]
  ]
  for slot in pool.slots.values.toSeq:
    futures.add((slot.projectFile, checkNimsuggestSlotKnowsURI(slot, uri)))  

  await allFutures(futures.mapIt(it[1]))
  futures.sort(proc(a, b: auto): int = cmp(a[0], b[0]))
  for (_, f) in futures:
    let res = f.read()
    if res.isSome:
      return res

proc addFileToOpenFiles*(
  ls: LanguageServer, 
  nimsuggestSlot: NimsuggestSlot,
  params: TextDocumentItem
) = 
  # Write the initial stash file
  let storagePath = ls.files.storageDir / (hash(params.uri).toHex & ".nim")
  try:
    writeFile(storagePath, params.text)
  except IOError as ex:
    warn "Failed to write stash file; hover/completion may show stale content",
      path = storagePath, msg = ex.msg
  except OSError as ex:
    warn "Failed to write stash file; hover/completion may show stale content",
      path = storagePath, msg = ex.msg

  # Build finger table for UTF-16 mapping
  var fingerTable: seq[seq[tuple[u16pos, offset: int]]] = @[]
  for line in params.text.splitLines:
    fingerTable.add(line.createUTFMapping())

  # Register in the file table (sync, atomic)
  let fileInfo = NlsFileInfo(
    slot: nimsuggestSlot,
    changed: false,
    fingerTable: fingerTable,
    textDocument: params,
  )
  ls.files.openFiles[params.uri] = fileInfo

  if params.uri in ls.files.idleOpenFiles:
    ls.files.idleOpenFiles.del(params.uri)

  # Register ownership in the slot (sync, atomic with above)
  nimsuggestSlot.assignUri(params.uri)

proc sortNimsuggestByDate(a, b: NimsuggestSlot): int = 
  if a.lastCmdTime == b.lastCmdTime:
    return 0
  elif a.lastCmdTime < b.lastCmdTime:
    return -1
  else:
    return 1

proc getLeastRecentlyUsedNimsuggestSlotInFullPool*(pool: NimsuggestPool): NimsuggestSlot =
  ## Returns the active slot with the oldest lastCmdTime.
  ## Returns nil if no active slots exist.
  let currentTime = now()
  # var nimsuggestInstances = sorted(sortNimsuggestByDate)
  var allSlots: seq[NimsuggestSlot] = @[]
  for slot in pool.slots.values.toSeq:
    allSlots.add(slot)
  let sortedSlots = sorted(allSlots, sortNimsuggestByDate)
  return sortedSlots[0]

proc lruAmong(slots: seq[NimsuggestSlot]): NimsuggestSlot =
  result = slots[0]
  for slot in slots[1..^1]:
    if slot.lastCmdTime < result.lastCmdTime:
      result = slot

proc nimsuggestSlotToEvict*(pool: NimsuggestPool): NimsuggestSlot =
  ## Selects the slot to evict from a full pool.
  ## Priority: CRASHED → STOPPING → READY → SPAWNING.
  ## Within each tier, the least recently used slot is chosen.
  ## Precondition: pool has at least one slot.
  assert pool.slots.len > 0, "nimsuggestSlotToEvict called on empty pool"

  for state in [SlotState.CRASHED, SlotState.STOPPING, SlotState.READY, SlotState.SPAWNING]:
    var candidates: seq[NimsuggestSlot]
    for slot in pool.slots.values:
      if slot.state == state:
        candidates.add(slot)
    if candidates.len > 0:
      return lruAmong(candidates)

  # Unreachable if precondition holds, but satisfies the compiler.
  raiseAssert "nimsuggestSlotToEvict: pool has slots but none matched any state"


proc queryFile*(ls: LanguageServer, uri: string, kind: NimsuggestQueryKind): Future[seq[Suggest]] =
  ## Creates a NimsuggestQuery and enqueues it on the owning slot's query mailbox.
  ## Returns a Future completed by processQueries when nimsuggest responds.
  result = newFuture[seq[Suggest]]("queryFile." & $kind)
  let fileInfo = ls.files.openFiles.getOrDefault(uri)
  if fileInfo == nil or fileInfo.slot == nil:
    result.complete(@[])
    return
  let dirtyFile = if fileInfo.changed: ls.uriStorageLocation(uri) else: ""
  fileInfo.slot.queryMailbox.addLastNoWait(NimsuggestQuery(
    kind: kind,
    uri: uri,
    dirtyFile: dirtyFile,
    responseFuture: result,
  ))

proc checkProject*(ls: LanguageServer, uri: string): Future[void] {.async.} =
  if ls.checkInProgress:
    return
  ls.checkInProgress = true
  defer:
    ls.checkInProgress = false
  let conf = ls.getWorkspaceConfiguration()
  if not conf.autoCheckProject.get(true):
    return
  let results = await ls.queryFile(uri, NimsuggestQueryKind.CHECK_PROJECT)
  ls.sendDiagnostics(results.filter(s => s.filePath != "???"), uri.uriToPath)

proc checkFile*(ls: LanguageServer, uri: string): Future[void] {.async.} =
  if uri notin ls.files.openFiles:
    return
  let fileInfo = ls.files.openFiles[uri]
  if fileInfo.slot == nil:
    return
  let conf = ls.getWorkspaceConfiguration()
  let useNimCheck = conf.useNimCheck.get(USE_NIM_CHECK_BY_DEFAULT)
  let nimPath = getNimPath(conf)
  let path = uriToPath(uri)
  if useNimCheck and nimPath.isSome:
    let checkResults = await nimCheck(path, nimPath.get)
    ls.sendDiagnostics(checkResults, path)
    return
  if fileInfo.changed:
    discard await ls.queryFile(uri, NimsuggestQueryKind.CHANGED)
  let results = await ls.queryFile(uri, NimsuggestQueryKind.CHECK_FILE)
  ls.sendDiagnostics(results.filter(s => s.filePath != "???"), path)

proc didCloseFile*(ls: LanguageServer, uri: string) =
  debug "Closed the following document:", uri = uri
  if uri notin ls.files.openFiles:
    return
  let fileInfo = ls.files.openFiles[uri]
  if fileInfo.changed:
    asyncSpawn ls.checkFile(uri)
  if fileInfo.slot != nil:
    fileInfo.slot.unassignUri(uri)
  ls.files.openFiles.del(uri)
  if fileInfo.cancelFileCheck != nil and not fileInfo.cancelFileCheck.finished:
    fileInfo.cancelFileCheck.complete()

proc makeIdleFile*(ls: LanguageServer, file: NlsFileInfo) =
  let uri = file.textDocument.uri
  if uri in ls.files.openFiles:
    ls.didCloseFile(uri)
    ls.files.idleOpenFiles[uri] = file
