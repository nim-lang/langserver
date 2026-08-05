import std/[options, sets, tables, times, sequtils, json, strformat]
import chronos
import chronicles
import ../nim_tools/nimsuggest/[nimsuggest_types, suggestapi]
import ./[utils, constants, queue_types]

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

proc processQueries*(slot: NimsuggestSlot, pool: NimsuggestPool) {.async.} =
  debug "processQueries: starting", projectFile = slot.projectFile
  while true:
    let q = await slot.queryMailbox.popFirst()

    # Wait until the slot has a live process.
    # If the slot is stopped/crashed, we still drain the queue so callers
    # get @[] rather than hanging forever.
    if slot.ns.isSome:
      try:
        discard await slot.ns.get # waits for SPAWNING → READY
      except CatchableError:
        # Process failed to start or crashed. Blame the in-flight URI so
        # didSave can unblock it (see fix #12C invariant).
        slot.crashedUris.incl(q.uri)
        if not q.responseFuture.finished:
          q.responseFuture.complete(@[])
        continue

    let nsOpt = slot.resolvedNs
    if nsOpt.isNone:
      if not q.responseFuture.finished:
        q.responseFuture.complete(@[])
      continue

    let ns = nsOpt.get

    # Detect crash: nimsuggest died after its Future completed (TCP socket closed).
    # project.markFailed is called by processQueue when content is empty.
    # We detect it here before dispatching so we don't send more commands to a dead process.
    debug "processQueries: pre-dispatch check",
      projectFile = slot.projectFile, kind = $q.kind, uri = q.uri,
      nsProjectFailed = ns.project.failed, slotState = $slot.state

    if ns.project.failed:
      debug "processQueries: nimsuggest marked failed",
        projectFile = slot.projectFile, slotState = $slot.state,
        crashCount = slot.crashCount, uri = q.uri

      if slot.state == SlotState.READY:
        slot.state = SlotState.CRASHED
        inc slot.crashCount
        debug "processQueries: detected nimsuggest crash, scheduling restart",
          projectFile = slot.projectFile, crashCount = slot.crashCount

        if slot.crashCount <= MAX_CRASH_RETRIES:
          slot.send SlotCommand(
            kind: SlotCommandKind.RESTART,
            spawnProjectFile: slot.projectFile,
            spawnTriggerUri: q.uri,
          )

        else:
          error "processQueries: crash limit reached, slot permanently failed",
            projectFile = slot.projectFile, crashCount = slot.crashCount

          if pool.notifyProc != nil:
            pool.notifyProc(
              "window/showMessage",
              %*{
                "type": 1,
                "message": fmt"Nimsuggest for {slot.projectFile} failed after {MAX_CRASH_RETRIES} attempts.",
              },
            )

          pool.removeSlot(slot.projectFile)

      slot.crashedUris.incl(q.uri)
      
      if not q.responseFuture.finished:
        q.responseFuture.complete(@[])
      continue

    slot.lastCmdTime = some(now())
  
    debug "processQueries: dispatching",
      projectFile = slot.projectFile, kind = $q.kind, uri = q.uri
      
    try:
      let queryResponse = await runNimsuggestQuery(q)
      if not q.responseFuture.finished:
        q.responseFuture.complete(queryResponse)

    except CatchableError as ex:
      debug "processQueries: query failed",
        projectFile = slot.projectFile, kind = $q.kind, msg = ex.msg
      slot.crashedUris.incl(q.uri)
      # What if the responseFuture is not finished?  How would this happen?
      if not q.responseFuture.finished:
        q.responseFuture.complete(@[]) # empty, not fail — see fix #17
