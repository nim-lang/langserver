import std/[options, sets, tables, times, sequtils, json, strformat]
import chronos
import chronicles
import ../nim_tools/nimsuggest/[nimsuggest_types, suggestapi]
import ./[utils, constants, queue_types]

# Nimsuggest TCP command queue types (defined first so NimsuggestSlot can use them)

type
  FilePosition* = object
    ## UTF-8 line (1-based) and column as used by nimsuggest.
    line*: int
    col*: int

  NimsuggestQueryKind* {.pure.} = enum
    # Completion / navigation
    SUGGEST           ## sug          — completion items at position
    DEFINITION        ## def          — go-to-definition
    DECLARATION       ## declaration  — go-to-declaration
    TYPE_DEFINITION   ## type         — go-to-type-definition
    REFERENCES        ## use          — find all references
    DOCUMENT_SYMBOLS  ## outline      — file symbol tree
    WORKSPACE_SYMBOLS ## globalSymbols — workspace-wide symbol search
    # Hover / highlighting
    HOVER              ## highlight — symbol info at position
    DOCUMENT_HIGHLIGHT ## highlight — all occurrences in file
    # Signature / inlay
    SIGNATURE_HELP ## con        — overload list at call site
    INLAY_HINTS    ## inlayHints — type / parameter / exception hints
    # Macro / ARC expansion
    EXPAND ## expand — macro expansion at position
    # File state
    CHANGED       ## changed — notify nimsuggest of unsaved edits (stash)
    CHECK_FILE    ## chkFile — per-file diagnostics
    CHECK_PROJECT ## chk     — full project diagnostics
    # Project management
    RECOMPILE ## recompile — force full in-process recompile
    KNOWN     ## known     — is this file in the module graph?

  NimsuggestQuery* = ref object
    id*: uint # Message id
    ## ref so the response future stays alive after the queue pops it.
    uri*: string
      ## Source URI. Used to resolve the on-disk path and stash path.
    dirtyFile*: string
      ## Stash path when openFiles[uri].changed is true, else "".
    responseFuture*: Future[seq[Suggest]]
      ## Completed by the query processor when nimsuggest replies.
      ## The LSP handler awaits this future; the processor completes it.
    cancelled*: bool
      ## Set by $/cancelRequest via PendingRequest.query.
      ## processQueries checks this before dispatching; if true, completes
      ## responseFuture with @[] immediately. Safe to write from any coroutine
      ## because NimsuggestQuery is a ref and Chronos is single-threaded.
    case kind*: NimsuggestQueryKind
    of NimsuggestQueryKind.SUGGEST, 
      NimsuggestQueryKind.DEFINITION, 
      NimsuggestQueryKind.DECLARATION, 
      NimsuggestQueryKind.TYPE_DEFINITION, 
      NimsuggestQueryKind.REFERENCES, 
      NimsuggestQueryKind.HOVER, 
      NimsuggestQueryKind.DOCUMENT_HIGHLIGHT, 
      NimsuggestQueryKind.SIGNATURE_HELP:
      position*: FilePosition

    of NimsuggestQueryKind.INLAY_HINTS:
      inlayHints*: tuple[
        start, finish: FilePosition,
        options: string # e.g. " +exceptionHints +parameterHints"
      ]

    of NimsuggestQueryKind.EXPAND:
      expand*: tuple[
        position:  FilePosition,
        tag: string # Tag passed to ns.expand for EXPAND queries (e.g. "" for expandAll,"  all" or "  2" for expand with level). Ignored for all other kinds.
      ]
    of NimsuggestQueryKind.DOCUMENT_SYMBOLS, 
      NimsuggestQueryKind.WORKSPACE_SYMBOLS, 
      NimsuggestQueryKind.CHANGED, 
      NimsuggestQueryKind.CHECK_FILE, 
      NimsuggestQueryKind.CHECK_PROJECT, 
      NimsuggestQueryKind.RECOMPILE, 
      NimsuggestQueryKind.KNOWN:
      discard

# === NIMSUGGEST QUERIES ===
proc initNimsuggestPositionQuery*(
  ls: LanguageServer,
  id: int,
  uri: string,
  kind: NimsuggestQueryKind,
  line, character: int,
): Option[NimsuggestQuery] =
  ## Create a position-based query (hover, definition, completion, …).
  ## line is 0-based (LSP convention); converted to 1-based for nimsuggest internally.
  ## The dirtyFile is resolved automatically from the stash.
  let column = toUtf8Col(ls, uri, line, character)
  if column.isNone:
    return none(NimsuggestQuery)
  else:
    ls.addProjectFileToPendingRequest(id.uint, uri)
    return some(NimsuggestQuery(
      id: id.uint,
      kind: kind,
      uri: uri,
      dirtyFile: ls.uriToStash(uri),
      responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
      position: FilePosition(line: line + 1, col: column.get),
    ))

proc initNimsuggestInlayHintQuery*(
  ls: LanguageServer,
  id: int,
  uri: string,
  startLine, startCharacter: int,
  endLine, endCharacter: int,
  inlayHintsOptions: string
): Option[NimsuggestQuery] =
  ## Create an inlay-hints range query.
  ## Lines are 0-based (LSP convention); converted to 1-based for nimsuggest internally.
  ## The dirtyFile is resolved automatically from the stash.
  let startColumn = toUtf8Col(ls, uri, startLine, startCharacter)
  let clampedEndLine =
    if uri in ls.files.openFiles:
      min(endLine, ls.files.openFiles[uri].fingerTable.len - 1)
    else:
      endLine
  let endColumn = toUtf8Col(ls, uri, clampedEndLine, endCharacter)
  if startColumn.isNone:
    return none(NimsuggestQuery)
  else:
    ls.addProjectFileToPendingRequest(id.uint, uri)
    return some(NimsuggestQuery(
      id: id.uint,
      kind: NimsuggestQueryKind.INLAY_HINTS,
      uri: uri,
      dirtyFile: ls.uriToStash(uri),
      responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
      inlayHints: (
        start: FilePosition(
          line: startLine + 1, col: startColumn.get
        ),
        finish: FilePosition(
          line: clampedEndLine + 1, col: endColumn.get(0)
        ),
        options: inlayHintsOptions
      )
    ))

proc initNimsuggestFileQuery*(
  ls: LanguageServer,
  id: int,
  uri: string,
  kind: NimsuggestQueryKind,
): NimsuggestQuery =
  ls.addProjectFileToPendingRequest(id.uint, uri)
  return NimsuggestQuery(
    id: id.uint,
    kind: kind,
    uri: uri,
    dirtyFile: ls.uriToStash(uri),
    responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
  )

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



proc processNimsuggestQuery*(slot: NimsuggestSlot, pool: NimsuggestPool) {.async.} =
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
