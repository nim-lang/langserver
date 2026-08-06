
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

