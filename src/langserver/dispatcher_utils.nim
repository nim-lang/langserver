import std/[options, sets, tables, algorithm, sequtils, strutils, times]
import chronos
import chronicles
import ../nimsuggest/[suggestapi, suggestapi_types, nimsuggest_types, nimsuggest_slots]
import ../protocol/types
import ./[utils as lsUtils]
import ./langserver_types
import ../utils/utils


func checkNimsuggestKnownResponse*(response: seq[Suggest]): bool = 
  ## Returns if the response indicates the file was known.
  # Checks response[0].forth == "true" — the boolean result comes back as a string in the forth field of a Suggest object.
  if response.len == 0:
    return false
  else:
    return response[0].forth == "true"

proc checkNimsuggestSlotKnowsURI(slot: NimsuggestSlot, uri: string): Future[Option[NimsuggestSlot]] {.async.} =
  case slot.state
  of SlotState.SPAWNING:
    try:
      let nimsuggestInstance: Nimsuggest = await slot.ns
      let knownQuery = NimsuggestQuery[LspFilePosition](
        id: 0.uint,
        kind: NimsuggestQueryKind.KNOWN,
        uri: uri,
        dirtyFile: "",
        responseFuture: newFuture[seq[Suggest]]("known"),
      )
      slot.queryMailbox.addLastNoWait(knownQuery)
      let response = await knownQuery.responseFuture
      let isKnown = checkNimsuggestKnownResponse(response)
      if isKnown:
        return some(slot)
      else:
        return none(NimsuggestSlot)
    except CatchableError:
      return none(NimsuggestSlot)

  of SlotState.READY:
    let nimsuggestInstance = slot.ns.read
    let knownQuery = NimsuggestQuery[LspFilePosition](
      id: 0.uint,
      kind: NimsuggestQueryKind.KNOWN,
      uri: uri,
      dirtyFile: "",
      responseFuture: newFuture[seq[Suggest]]("known"),
    )
    slot.queryMailbox.addLastNoWait(knownQuery)
    let response = await knownQuery.responseFuture
    let isKnown = checkNimsuggestKnownResponse(response)
    if isKnown:
      return some(slot)
    else:
      return none(NimsuggestSlot)
  of SlotState.STOPPED, SlotState.STOPPING, SlotState.CRASHED:
    return none(NimsuggestSlot)


proc isKnownByANimsuggestSlot*(pool: NimsuggestPool, uri: string): Future[Option[NimsuggestSlot]] {.async.} =
  var futures: seq[Future[Option[NimsuggestSlot]]]

  for slot in pool.slots.values.toSeq:
    futures.add(checkNimsuggestSlotKnowsURI(slot, uri))

  await allFutures(futures)
  var possibleNimsuggestSlots: seq[NimsuggestSlot] = @[]
  for f in futures:
    let res = f.read()
    if res.isSome:
      possibleNimsuggestSlots.add(res.get())

  possibleNimsuggestSlots.sort(proc(a, b: NimsuggestSlot): int = cmp(a.projectFile, b.projectFile))

  if possibleNimsuggestSlots.len > 0:
    return some(possibleNimsuggestSlots[0])
  else:
    return none(NimsuggestSlot)

proc addFileToOpenFiles*(
  ls: LanguageServer, 
  nimsuggestSlot: NimsuggestSlot,
  params: TextDocumentItem
) = 
  # Write the initial stash file
  let storagePath = ls.uriStorageLocation(params.uri)
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
  # Also sync the live NimSuggest's openFiles set so getLspStatus displays correctly.
  # execSpawn copies ownedUris → ns.openFiles at spawn time, but files opened on an
  # already-READY slot are not reached by that path.
  if nimsuggestSlot.state == SlotState.READY:
    nimsuggestSlot.ns.read.openFiles.incl(params.uri)

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

  for state in [SlotState.STOPPED, SlotState.CRASHED, SlotState.STOPPING, SlotState.READY, SlotState.SPAWNING]:
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
  result = newFuture[seq[Suggest]]("queryFile")
  let fileInfo = ls.files.openFiles.getOrDefault(uri)
  if fileInfo == nil or fileInfo.slot == nil:
    result.complete(@[])
    return
  let dirtyFile = if fileInfo.changed: ls.uriStorageLocation(uri) else: ""
  fileInfo.slot.queryMailbox.addLastNoWait(NimsuggestQuery[LspFilePosition](
    kind: kind,
    uri: uri,
    dirtyFile: dirtyFile,
    responseFuture: result,
  ))

