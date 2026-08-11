import std/[options, strutils, sets, tables, times, json]
import chronos
import chronicles
import ../utils/utils
import ./[suggestapi, suggestapi_types, nimsuggest_types, nimsuggest_slots, diagnostics]
import ../protocol/types

proc getFilePath*(s: Suggest): FilePath = s.filePath

func toNimsuggestFilePosition*(
  position: LspFilePosition,
  uri: FileUri,
  openFiles: TableRef[FileUri, NlsFileInfo]
): Option[NimsuggestFilePosition] =
  # Finger tables are 0-based
  if uri in openFiles and int(position.line) < openFiles[uri].fingerTable.len:
    return some(
      NimsuggestFilePosition(
        line: int(position.line) + 1,
        col: openFiles[uri].fingerTable[int(position.line)].utf16to8(int(position.character))
      ))
  else:
    return none(NimsuggestFilePosition)

func toNimsuggestQuery*(
  q: NimsuggestQuery[LspFilePosition],
  openFiles: TableRef[FileUri, NlsFileInfo]
): Option[NimsuggestQuery[NimsuggestFilePosition]] =
  ## Converts a LSP-space query to a nimsuggest-space query, translating
  ## positions from (0-based line, UTF-16 col) to (1-based line, UTF-8 col)
  ## via the finger table in openFiles.
  ##
  ## The responseFuture is shared — not re-created — so any coroutine already
  ## awaiting q.responseFuture will observe the result when the converted query
  ## is completed by processNimsuggestQueries.
  ##
  ## Returns none if position conversion fails (URI not in openFiles, or line
  ## out of range). Always succeeds for position-less query kinds.
  case q.kind
  of NimsuggestQueryKind.SUGGEST,
    NimsuggestQueryKind.DEFINITION,
    NimsuggestQueryKind.DECLARATION,
    NimsuggestQueryKind.TYPE_DEFINITION,
    NimsuggestQueryKind.REFERENCES,
    NimsuggestQueryKind.HOVER,
    NimsuggestQueryKind.DOCUMENT_HIGHLIGHT,
    NimsuggestQueryKind.SIGNATURE_HELP:
    let posOpt = toNimsuggestFilePosition(q.position, q.uri, openFiles)
    if posOpt.isNone:
      return none(NimsuggestQuery[NimsuggestFilePosition])
    # Two-step construction required: Nim disallows putting both a runtime
    # discriminant (kind: q.kind) and a variant field (position:) in the
    # same object constructor. Assign position after construction instead.
    var converted = NimsuggestQuery[NimsuggestFilePosition](
      id: q.id, uri: q.uri, dirtyFile: q.dirtyFile,
      responseFuture: q.responseFuture, cancelled: q.cancelled,
      kind: q.kind,
    )
    converted.position = posOpt.get()
    some(converted)
  of NimsuggestQueryKind.INLAY_HINTS:
    let startOpt = toNimsuggestFilePosition(q.inlayHints.start, q.uri, openFiles)
    let finishOpt = toNimsuggestFilePosition(q.inlayHints.finish, q.uri, openFiles)
    if startOpt.isNone or finishOpt.isNone:
      return none(NimsuggestQuery[NimsuggestFilePosition])
    some(NimsuggestQuery[NimsuggestFilePosition](
      id: q.id, uri: q.uri, dirtyFile: q.dirtyFile,
      responseFuture: q.responseFuture, cancelled: q.cancelled,
      kind: NimsuggestQueryKind.INLAY_HINTS,
      inlayHints: (
        start: startOpt.get(),
        finish: finishOpt.get(),
        options: q.inlayHints.options,
      ),
    ))
  of NimsuggestQueryKind.EXPAND:
    let posOpt = toNimsuggestFilePosition(q.expand.position, q.uri, openFiles)
    if posOpt.isNone:
      return none(NimsuggestQuery[NimsuggestFilePosition])
    some(NimsuggestQuery[NimsuggestFilePosition](
      id: q.id, uri: q.uri, dirtyFile: q.dirtyFile,
      responseFuture: q.responseFuture, cancelled: q.cancelled,
      kind: NimsuggestQueryKind.EXPAND,
      expand: (position: posOpt.get(), tag: q.expand.tag),
    ))
  of NimsuggestQueryKind.DOCUMENT_SYMBOLS,
    NimsuggestQueryKind.WORKSPACE_SYMBOLS,
    NimsuggestQueryKind.CHANGED,
    NimsuggestQueryKind.CHECK_FILE,
    NimsuggestQueryKind.CHECK_PROJECT,
    NimsuggestQueryKind.RECOMPILE,
    NimsuggestQueryKind.KNOWN:
    some(NimsuggestQuery[NimsuggestFilePosition](
      id: q.id, uri: q.uri, dirtyFile: q.dirtyFile,
      responseFuture: q.responseFuture, cancelled: q.cancelled,
      kind: q.kind,
    ))

# === PROCESSING ===
proc runNimsuggestQuery*(
  ns: Nimsuggest, 
  q: NimsuggestQuery[NimsuggestFilePosition],
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

proc mailboxHasQueryOfKind(
  slot: NimsuggestSlot, 
  queryKind: NimsuggestQueryKind,
  uri: FileUri, 
): bool = 
  result = false
  for queueQuery in slot.queryMailbox.items():
    if queueQuery.kind == NimsuggestQueryKind.CHANGED and queueQuery.uri == uri:
      return true

proc mailboxHasChangedQueryForSameUriAnyOtherUri(
  slot: NimsuggestSlot, 
  uri: FileUri, 
): bool = 
  ## Checks if there is another KIND messages for the same URI later in the queue, but with no other KIND queries for other URIs in between.
  result = false
  for queueQuery in slot.queryMailbox.items():
    if queueQuery.kind == NimsuggestQueryKind.CHANGED:
      if queueQuery.uri == uri:
        return true
      else:
        return false

proc processNimsuggestQueries*(
  slot: NimsuggestSlot, 
  pool: NimsuggestPool,
  openFiles: TableRef[FileUri, NlsFileInfo],
  notifyProc: proc(name: string, params: JsonNode) {.gcsafe, raises: [].} #Send a notification to the client
) {.async.} =
  debug "processNimsuggestQueries: starting", projectFile = slot.projectFile
  while true:
    debug "processNimsuggestQueries: waiting for query", projectFile = slot.projectFile, mailboxLen = slot.queryMailbox.len

    let originalQuery = await slot.queryMailbox.popFirst()

    debug "processNimsuggestQueries: running query", kind = $originalQuery.kind, projectFile = slot.projectFile, uri = originalQuery.uri

    # $/cancelRequest — skip queries already cancelled by the client.
    if originalQuery.cancelled:
      debug "processNimsuggestQueries: query cancelled, skipping", kind = $originalQuery.kind, uri = originalQuery.uri
      if not originalQuery.responseFuture.finished:
        originalQuery.responseFuture.complete(@[])
      continue

    case originalQuery.kind
    of NimsuggestQueryKind.CHANGED:
      if mailboxHasChangedQueryForSameUriAnyOtherUri(slot, originalQuery.uri):
        # If there is a later changed query for the same uri queued, drop this one.  There must be no CHANGED queries to other URIs in between, though.
        debug "processNimsuggestQueries: There is a later CHANGED query for the same uri.", uri = originalQuery.uri
        originalQuery.responseFuture.complete(@[])
        continue
      else:
        if originalQuery.uri in openFiles:
          let fileInfo = openFiles[originalQuery.uri]
          let timeSinceLastChange = now() - fileInfo.lastChanged

          if timeSinceLastChange < pool.fileCheckDelay:
            # Not enough time has elapsed
            let timeoutLength = (pool.fileCheckDelay - timeSinceLastChange).inMilliseconds + 5
            debug "processNimsuggestQueries: Running timeout for CHANGED.", timeout = timeoutLength, uri = originalQuery.uri
            # Start a blocking timer until the remaining time has elapsed
            await sleepAsync(timeoutLength)
            # Add the message back onto the front of the queue.
            slot.queryMailbox.addFirstNoWait(originalQuery)
            continue
          # else: enough time has passed, continue with processing the query...
        else:
          debug "processNimsuggestQueries: Skipping query, file is no longer open.", uri = originalQuery.uri
          continue

    
    of NimsuggestQueryKind.CHECK_FILE:
      discard
      # if mailboxHasQueryOfKind(
      #   slot, NimsuggestQueryKind.CHECK_FILE, originalQuery.uri
      # ):
      #   debug "processNimsuggestQueries: skipping stale query (CHECK_FILE pending)", kind = $originalQuery.kind, uri = originalQuery.uri
      #   originalQuery.responseFuture.complete(@[])
      #   continue

    of NimsuggestQueryKind.CHECK_PROJECT:
      discard
    of NimsuggestQueryKind.RECOMPILE:
      discard
    of 
      NimsuggestQueryKind.SUGGEST,
      NimsuggestQueryKind.DOCUMENT_SYMBOLS, 
      NimsuggestQueryKind.INLAY_HINTS,
      NimsuggestQueryKind.HOVER,
      NimsuggestQueryKind.DOCUMENT_HIGHLIGHT,
      NimsuggestQueryKind.SIGNATURE_HELP:
      # skip if a newer query, or if a CHANGED is still pending (AST is
      # stale — results would be wrong anyway and VS Code will re-request).
      if mailboxHasQueryOfKind(
        slot, NimsuggestQueryKind.CHANGED, originalQuery.uri
      ):
        debug "processNimsuggestQueries: skipping stale query (CHANGED pending)", kind = $originalQuery.kind, uri = originalQuery.uri
        originalQuery.responseFuture.complete(@[])
        continue
      elif mailboxHasQueryOfKind(
        slot, originalQuery.kind, originalQuery.uri
      ):
        debug "processNimsuggestQueries: skipping stale query (a newer request is later in the queue)", kind = $originalQuery.kind, uri = originalQuery.uri
        originalQuery.responseFuture.complete(@[])
        continue

    of 
      NimsuggestQueryKind.DEFINITION,
      NimsuggestQueryKind.DECLARATION,
      NimsuggestQueryKind.TYPE_DEFINITION,
      NimsuggestQueryKind.REFERENCES,
      NimsuggestQueryKind.WORKSPACE_SYMBOLS,
      NimsuggestQueryKind.EXPAND,
      NimsuggestQueryKind.KNOWN:
      discard

    # Wait for spawning slot
    if slot.state == SlotState.SPAWNING: 
      try:
        debug "processNimsuggestQueries: Waiting for slot to spawn."
        discard await slot.ns # waits for SPAWNING → READY
      except CatchableError:
        debug "processNimsuggestQueries: Failed to spawn slot."
        # Process failed to start or crashed. Blame the in-flight URI so
        # didSave can unblock it (see fix #12C invariant).
        slot.crashedUris.incl(originalQuery.uri)
        if not originalQuery.responseFuture.finished:
          originalQuery.responseFuture.complete(@[])
        continue

    case slot.state 
    of SlotState.SPAWNING, SlotState.CRASHED, SlotState.STOPPING, SlotState.STOPPED:
      debug "processNimsuggestQueries: Could not process query, slot was SPAWNING, CRASHED OR STOPPING.", state = slot.state
      if not originalQuery.responseFuture.finished:
        originalQuery.responseFuture.complete(@[])

    of SlotState.READY:
      if slot.ns.read().project.failed:
        let respawnWasSuccessful = await attemptCrashRespawn(slot, pool)
        if not respawnWasSuccessful:
          slot.crashedUris.incl(originalQuery.uri)
          if not originalQuery.responseFuture.finished:
            originalQuery.responseFuture.complete(@[])
          continue
      
    if slot.state == SlotState.READY:
      let convertedQuery = toNimsuggestQuery(originalQuery, openFiles)
      if convertedQuery.isNone:
        debug "processNimsuggestQueries: query conversion failed, skipping"
        originalQuery.responseFuture.complete(@[])
        continue

      else: 
        let q = convertedQuery.get()
        debug "processNimsuggestQueries: query about to be run ", projectFile = slot.projectFile, kind = $q.kind, uri = $q.uri
        try:
          # === RUNNING NIMSUGGEST QUERY ===
          let queryResponse: seq[Suggest] = await runNimsuggestQuery(slot.ns.read(), q)
          q.responseFuture.complete(queryResponse)
          # HERE IS WHERE YOU NEED TO SEND THE DIAGNOSTICS!
          case q.kind
          of NimsuggestQueryKind.CHANGED: 
            # The change was successful, therefore check the file.
            if q.uri in openFiles:
              openFiles[q.uri].lastChanged = now()

            let checkQuery = NimsuggestQuery[LspFilePosition](
              id: 0,
              kind: NimsuggestQueryKind.CHECK_FILE,
              uri: q.uri,
              dirtyFile: q.dirtyFile,
              responseFuture: newFuture[seq[Suggest]]("checkFile"),
            )
            
            slot.queryMailbox.addFirstNoWait(checkQuery)

          of NimsuggestQueryKind.CHECK_FILE:  
            if q.uri in openFiles:
              openFiles[q.uri].lastChecked = now()

            let diagnosticsJson = convertNimSuggestResponseToDiagnostics(
              queryResponse, q.uri, openFiles
            )

            notifyProc("textDocument/publishDiagnostics", diagnosticsJson)
            
            debug "processNimsuggestQueries: CHECK_FILE run, sending diagnostics ", uri = $q.uri, json = diagnosticsJson
            
          of NimsuggestQueryKind.CHECK_PROJECT, NimsuggestQueryKind.RECOMPILE:
            let timeNow = now()
            for uri, file in openFiles:
              openFiles[uri].lastChecked = timeNow

            for (path, groupedSuggests) in groupBy(queryResponse, getFilepath):
              let diagnosticsJson = convertNimSuggestResponseToDiagnostics(
                groupedSuggests, pathToUri(path), openFiles
              )
              notifyProc("textDocument/publishDiagnostics", diagnosticsJson)
              
          else:
            discard

          debug "processQueries: query finished running ", projectFile = slot.projectFile, kind = $q.kind

        except CatchableError as ex:
          debug "processQueries: query failed",
            projectFile = slot.projectFile, kind = $q.kind, msg = ex.msg
          
          slot.crashedUris.incl(q.uri)
          
          if not q.responseFuture.finished:
            q.responseFuture.complete(@[]) # empty, not fail — see fix #17

