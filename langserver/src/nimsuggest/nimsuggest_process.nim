import std/[json, options, strformat, strutils, sets, tables, times]
import chronos
import chronicles
import ../utils/utils
import ./[suggestapi, suggestapi_types, nimsuggest_types, nimsuggest_slots]
import ../configurations/constants
import ../protocol/types

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

proc processNimsuggestQueries*(
  slot: NimsuggestSlot, pool: NimsuggestPool,
  openFiles: TableRef[FileUri, NlsFileInfo]
) {.async.} =
  debug "processQueries: starting", projectFile = slot.projectFile
  while true:
    debug "processQueries: waiting for query", projectFile = slot.projectFile, mailboxLen = slot.queryMailbox.len
    let q = await slot.queryMailbox.popFirst()
    debug "processQueries: dequeued query", projectFile = slot.projectFile, kind = $q.kind, uri = q.uri

    # Wait until the slot has a live process.
    # If the slot is stopped/crashed, we still drain the queue so callers
    # get @[] rather than hanging forever.
    if slot.state in {SlotState.SPAWNING, SlotState.READY}:
      try:
        discard await slot.ns # waits for SPAWNING → READY
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
    if ns.project.failed:
      if slot.state == SlotState.READY:
        slot.state = SlotState.CRASHED
        inc slot.crashCount
        if slot.crashCount <= MAX_CRASH_RETRIES:
          let backoffMs = if slot.crashCount > 0:
            min(1_000 * (1 shl min(slot.crashCount - 1, 14)), 30_000)
          else: 0
          if backoffMs > 0:
            await sleepAsync(backoffMs)
          discard await execStop(slot, pool)
          slot.crashedUris.clear() # explicit restart = clean slate
          discard await execSpawn(slot, pool, slot.projectFile)

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

    slot.lastCmdTime = times.now()

    try:
      debug "processQueries: query about to be run ", projectFile = slot.projectFile, kind = $q.kind
      let convertedQuery = toNimsuggestQuery(q, openFiles)
      if convertedQuery.isNone:
        # Position conversion failed (URI not in openFiles or line out of range).
        # Complete with empty rather than hanging the caller.
        if not q.responseFuture.finished:
          q.responseFuture.complete(@[])
      else:
        let queryResponse = await runNimsuggestQuery(ns, convertedQuery.get())
        debug "processQueries: query finished running ", projectFile = slot.projectFile, kind = $q.kind
        if not q.responseFuture.finished:
          q.responseFuture.complete(queryResponse)

    except CatchableError as ex:
      debug "processQueries: query failed",
        projectFile = slot.projectFile, kind = $q.kind, msg = ex.msg
      slot.crashedUris.incl(q.uri)
      # What if the responseFuture is not finished?  How would this happen?
      if not q.responseFuture.finished:
        q.responseFuture.complete(@[]) # empty, not fail — see fix #17

