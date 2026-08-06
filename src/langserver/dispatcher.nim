import std/[options, tables, algorithm]
import chronos
import chronicles
import ../nim_tools/nimsuggest/[suggestapi, nimsuggest_types]
import ../langserver/[utils, langserver_types, queue_types, queues]
import ../protocol/[enums, types]




proc runFileAccessQuery*(ls: LanguageServer, query: FileAccessQuery) =
  case query.kind
  of FileAccessQueryKind.DID_OPEN:
    discard  # → ls.didOpenFile(query.didOpen.textDocument)
  of FileAccessQueryKind.DID_CHANGE:
    discard  # → ls.didChange(query.didChange)
  of FileAccessQueryKind.DID_SAVE:
    discard  # → ls.didSave(query.didSave)
  of FileAccessQueryKind.DID_CLOSE:
    discard  # → ls.didCloseFile(query.didClose.textDocument.uri)
  of FileAccessQueryKind.WILL_SAVE_WAIT_UNTIL:
    discard  # request (returns seq[TextEdit]) — handled by the request path
  of FileAccessQueryKind.DID_RENAME_FILES:
    discard  # → for r in query.renameFiles.files: ls.didRenameFile(r.oldUri, r.newUri)
  of FileAccessQueryKind.DID_DELETE_FILES:
    discard  # → for f in query.deleteFiles.files: ls.didDeleteFile(f.uri)
  of FileAccessQueryKind.DID_CHANGE_CONFIGURATION:
    discard  # config changes handled via the configReady AsyncEvent


# === PROCESSING === 
proc runNimsuggestQuery*(
  ns: Nimsuggest, 
  q: NimsuggestQuery
): Future[seq[Suggest]] {.async.} =
  let path = q.uri.uriToPath
  case q.kind
  of NimsuggestQueryKind.SUGGEST:
    return await ns.sug(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.DEFINITION:
    return await ns.def(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.DECLARATION:
    return await ns.declaration(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.TYPE_DEFINITION:
    return await ns.type(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.REFERENCES:
    return await ns.use(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.HOVER, NimsuggestQueryKind.DOCUMENT_HIGHLIGHT:
    return await ns.highlight(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.SIGNATURE_HELP:
    return await ns.con(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.DOCUMENT_SYMBOLS:
    return await ns.outline(path, q.dirtyFile)
  of NimsuggestQueryKind.WORKSPACE_SYMBOLS:
    return await ns.globalSymbols(path, q.dirtyFile)
  of NimsuggestQueryKind.INLAY_HINTS:
    return await ns.inlayHints(
      path, q.dirtyFile,
      q.inlayHints.start.line, q.inlayHints.start.col,
      q.inlayHints.finish.line, q.inlayHints.finish.col,
      q.inlayHints.options
    )
  of NimsuggestQueryKind.EXPAND:
    return await ns.expand(
      path, 
      q.dirtyFile, 
      q.expand.position.line, q.expand.position.col, 
      q.expand.tag
    )
  of NimsuggestQueryKind.CHANGED:
    return await ns.changed(path, q.dirtyFile)
  of NimsuggestQueryKind.CHECK_FILE:
    return await ns.chkFile(path, q.dirtyFile)
  of NimsuggestQueryKind.CHECK_PROJECT:
    return await ns.chk(path, q.dirtyFile)
  of NimsuggestQueryKind.RECOMPILE:
    return await ns.recompile()
  of NimsuggestQueryKind.KNOWN:
    return await ns.known(path)

# proc processNimsuggestQuery*(slot: NimsuggestSlot, pool: NimsuggestPool) {.async.} =
#   debug "processQueries: starting", projectFile = slot.projectFile
#   while true:
#     let q = await slot.queryMailbox.popFirst()

#     # Wait until the slot has a live process.
#     # If the slot is stopped/crashed, we still drain the queue so callers
#     # get @[] rather than hanging forever.
#     if slot.ns.isSome:
#       try:
#         discard await slot.ns.get # waits for SPAWNING → READY
#       except CatchableError:
#         # Process failed to start or crashed. Blame the in-flight URI so
#         # didSave can unblock it (see fix #12C invariant).
#         slot.crashedUris.incl(q.uri)
#         if not q.responseFuture.finished:
#           q.responseFuture.complete(@[])
#         continue

#     let nsOpt = slot.resolvedNs
#     if nsOpt.isNone:
#       if not q.responseFuture.finished:
#         q.responseFuture.complete(@[])
#       continue

#     let ns = nsOpt.get

#     # Detect crash: nimsuggest died after its Future completed (TCP socket closed).
#     # project.markFailed is called by processQueue when content is empty.
#     # We detect it here before dispatching so we don't send more commands to a dead process.
#     debug "processQueries: pre-dispatch check",
#       projectFile = slot.projectFile, kind = $q.kind, uri = q.uri,
#       nsProjectFailed = ns.project.failed, slotState = $slot.state

#     if ns.project.failed:
#       debug "processQueries: nimsuggest marked failed",
#         projectFile = slot.projectFile, slotState = $slot.state,
#         crashCount = slot.crashCount, uri = q.uri

#       if slot.state == SlotState.READY:
#         slot.state = SlotState.CRASHED
#         inc slot.crashCount
#         debug "processQueries: detected nimsuggest crash, scheduling restart",
#           projectFile = slot.projectFile, crashCount = slot.crashCount

#         if slot.crashCount <= MAX_CRASH_RETRIES:
#           slot.send SlotCommand(
#             kind: SlotCommandKind.RESTART,
#             spawnProjectFile: slot.projectFile,
#             spawnTriggerUri: q.uri,
#           )

#         else:
#           error "processQueries: crash limit reached, slot permanently failed",
#             projectFile = slot.projectFile, crashCount = slot.crashCount

#           if pool.notifyProc != nil:
#             pool.notifyProc(
#               "window/showMessage",
#               %*{
#                 "type": 1,
#                 "message": fmt"Nimsuggest for {slot.projectFile} failed after {MAX_CRASH_RETRIES} attempts.",
#               },
#             )

#           pool.removeSlot(slot.projectFile)

#       slot.crashedUris.incl(q.uri)
      
#       if not q.responseFuture.finished:
#         q.responseFuture.complete(@[])
#       continue

#     slot.lastCmdTime = some(now())
  
#     debug "processQueries: dispatching",
#       projectFile = slot.projectFile, kind = $q.kind, uri = q.uri
      
#     try:
#       let queryResponse = await runNimsuggestQuery(q)
#       if not q.responseFuture.finished:
#         q.responseFuture.complete(queryResponse)

#     except CatchableError as ex:
#       debug "processQueries: query failed",
#         projectFile = slot.projectFile, kind = $q.kind, msg = ex.msg
#       slot.crashedUris.incl(q.uri)
#       # What if the responseFuture is not finished?  How would this happen?
#       if not q.responseFuture.finished:
#         q.responseFuture.complete(@[]) # empty, not fail — see fix #17



# alternate version of the `isKnown` function 
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

  let ns = await slot.ns.get()  # already resolved, returns immediately
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


  # var best: NimsuggestSlot = nil
  # var bestSeconds = low(float)

  # for slot in pool.slots.values:
  #   if not slot.isActive:
  #     continue
  #   let secondsIdle = (currentTime.toTime - slot.lastCmdTime.toTime).inSeconds.float
  #   if secondsIdle > bestSeconds:
  #     bestSeconds = secondsIdle
  #     best = slot

  # best

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

proc processLangserverQueue*(ls: LanguageServer): Future[void] {.async.} =
  ## Single coroutine that drains ls.langserverQueue in FIFO order.
  ##
  ## All LSP-triggered work — file operations and nimsuggest queries alike —
  ## flows through this queue. Processing order matches LSP message arrival
  ## order, guaranteeing that a didChange stash write is applied before any
  ## subsequent hover query is dispatched to the per-slot mailbox.
  ##
  ## Invariant: use `while true` not tail recursion. Each recursive async call
  ## creates a new Future object that is never freed until the chain resolves
  ## (which for an infinite loop means never), corrupting the heap under ORC.
  while true:
    let query = await ls.langserverQueue.popFirst()
    case query.kind
    of LangserverQueryKind.NIMSUGGEST:
      let q = query.nimsuggest
      # First, check if the current file is owned by a nimsuggest instance
      let fileInfo = ls.files.openFiles.getOrDefault(q.uri)
      if fileInfo != nil:
        # NimsuggestSlot is a ref object, so fileInfo.slot is just a pointer to the same heap object that lives in pool.slots[projectFile].
        fileInfo.slot.queryMailbox.addLastNoWait(q)
      else:
        q.responseFuture.complete(@[])
      
    of LangserverQueryKind.FILE_ACCESS:
      let q = query.fileAccess
      case q.kind
      of FileAccessQueryKind.DID_OPEN:
        let uri = q.didOpen.textDocument.uri
        # Check if file is already open
        if uri in ls.files.openFiles:
          debug "didOpenFile: URI already tracked, skipping", uri = uri
        
        else:
          # Check if file is known to any nimsuggest instance
          let fileIsKnown: Option[NimsuggestSlot] = await isKnownByANimsuggestSlot(ls.pool, uri)
          if fileIsKnown.isSome:
            ls.addFileToOpenFiles(fileIsKnown.get(), q.didOpen.textDocument)
          else:
            # This file is not known by any running nimsuggest instance.

            # Find the correct entry point for this file, otherwise, treat the file as an orphan and run nimsuggest using it as the projectFile.
            var projectFile = uriToPath(uri)
            let correctProjectFile = getIntendedProject(ls, uri)
            if correctProjectFile.len > 0:
              projectFile = correctProjectFile
            
            if ls.pool.canSpawn:
              # Free slot available — create a new nimsuggest instance.
              let newSlot = NimsuggestSlot(
                state: SlotState.SPAWNING,
                projectFile: projectFile,
                ownedUris: initHashSet[string](),
                ns: none(Future[NimSuggest]),
                queryMailbox: newAsyncQueue[NimsuggestQuery](),
                lastCmdTime: times.now(),
                isEntryPoint: projectPath == correctProjectFile,
                crashedUris: initHashSet[string](),
              )
              ls.pool.addSlot(s)
              # Start the query queue running
              let successfulSpawn: bool = await execSpawn(newSlot, pool, projectFile)
              if successfulSpawn:
                discard await newSlot.ns.get()
                ls.addFileToOpenFiles(fileIsKnown.get(), q.didOpen.textDocument)
                asyncSpawn processQueries(newSlot, ls.pool)
              else:
                pool.removeSlot(projectFile)

            else:
              # Pool at capacity — evict a slot.
              let slotToEvict = nimsuggestSlotToEvict(ls.pool)
              while slotToEvict.queryMailbox.len > 0:
                let pendingQ = lruSlot.queryMailbox.popFirstNoWait()
                if not pendingQ.responseFuture.finished:
                  pendingQ.responseFuture.complete(@[])

              let successfulStop = execStop(slotToEvict)
              if successfulStop:
                ls.pool.removeSlot(slotToEvict)
                
              # Create a new slot
              let newSlot = NimsuggestSlot(
                state: SlotState.SPAWNING,
                projectFile: projectFile,
                ownedUris: initHashSet[string](),
                ns: none(Future[NimSuggest]),
                queryMailbox: newAsyncQueue[NimsuggestQuery](),
                lastCmdTime: times.now(),
                isEntryPoint: projectPath == correctProjectFile,
                crashedUris: initHashSet[string](),
              )
              ls.pool.addSlot(s)
              # Start the query queue running
              let successfulSpawn = await execSpawn(newSlot, pool, projectFile)
              if successfulSpawn:
                discard await newSlot.ns.get()
                ls.addFileToOpenFiles(fileIsKnown.get(), q.didOpen.textDocument)
                asyncSpawn processQueries(newSlot, ls.pool)
              else:
                debug "Failed to spawn nimsuggest for file", uri = uri
            
      of FileAccessQueryKind.DID_CHANGE:
        let uri = q.didChange.textDocument.uri
        let contentChanges = q.didChange.contentChanges
    
        if uri notin ls.files.openFiles:
          return
        let file = open(ls.uriStorageLocation(uri), fmWrite)

        ls.files.openFiles[uri].fingerTable = @[]
        ls.files.openFiles[uri].changed = true
        if contentChanges.len <= 0:
          file.close()
          return
        for line in contentChanges[0].text.splitLines:
          ls.files.openFiles[uri].fingerTable.add line.createUTFMapping()
          file.writeLine line
        file.close()
        # I have removed the scheduled file-checking that runs after the user has not been typing for 1 second, or so, and instead just have this run on the user saving.

      of FileAccessQueryKind.DID_SAVE:
        discard  # → ls.didSave(query.didSave)
      of FileAccessQueryKind.DID_CLOSE:
        discard  # → ls.didCloseFile(query.didClose.textDocument.uri)
      of FileAccessQueryKind.WILL_SAVE_WAIT_UNTIL:
        discard  # request (returns seq[TextEdit]) — handled by the request path
      of FileAccessQueryKind.DID_RENAME_FILES:
        discard  # → for r in query.renameFiles.files: ls.didRenameFile(r.oldUri, r.newUri)
      of FileAccessQueryKind.DID_DELETE_FILES:
        discard  # → for f in query.deleteFiles.files: ls.didDeleteFile(f.uri)
      of FileAccessQueryKind.DID_CHANGE_CONFIGURATION:
        discard  # config changes handled via the configReady AsyncEvent
