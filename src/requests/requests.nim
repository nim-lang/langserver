## requests.nim
##
## The routing layer: translates LSP handler calls into per-slot queue entries.
##
## PROBLEM THIS SOLVES
## ═══════════════════
## Previously, lsp.nim handlers called tryGetNimsuggest(uri) to obtain a raw
## NimSuggest handle, then called suggestapi procs directly:
##
##   # OLD — bypasses the queue entirely
##   let ns = await ls.tryGetNimsuggest(uri)
##   if ns.isNone: return none(Hover)
##   let results = await ns.get.highlight(path, stash, line+1, col)
##
## This broke:
##   • LRU tracking     — slot.lastCmdTime never updated (LRU eviction wrong)
##   • Serialization    — concurrent calls hit the same TCP socket
##   • Spawn dependency — no guarantee nimsuggest was READY before the call
##   • Crash tracking   — slot.crashedUris never set for direct calls
##   • Timeout unity    — each handler could impose its own timeout independently
##
## THE FIX
## ═══════
## routeQuery() replaces every tryGetNimsuggest + direct suggestapi call.
## It is SYNCHRONOUS (no await), so it is atomic under Chronos's cooperative
## scheduler. The slot lookup and the enqueue happen without any yield point
## between them:
##
##   # NEW — goes through the slot's queryMailbox
##   let results = await ls.routeQuery(uri, NimsuggestQuery(
##     kind:           NimsuggestQueryKind.HOVER,
##     uri:            uri,
##     dirtyFile:      ls.uriToStash(uri),
##     responseFuture: newFuture[seq[Suggest]]("hover"),
##     position:       FilePosition(line: line + 1, col: col),
##   ))
##
## processQueries (in queues.nim) then:
##   1. Awaits slot.ns.get  →  blocks here if the slot is still SPAWNING
##   2. Calls ns.highlight(…) via suggestapi
##   3. Completes responseFuture with the result
##
## The LSP handler just awaits responseFuture. It never sees the NimSuggest
## handle or the spawn state — all of that is encapsulated in the slot.
##
## WHY NO GLOBAL REQUEST QUEUE
## ════════════════════════════
## You asked whether every lsp.nim call should add a message to THE queue.
## The answer depends on what "the queue" means:
##
##   Global FIFO queue (one for the whole server):
##     ✗  Would serialize hover on file_a with hover on file_b, even though
##        they run on separate nimsuggest processes and are fully independent.
##
##   Per-slot queue (one per nimsuggest process):
##     ✓  Serializes all queries within a slot (correct — one TCP connection).
##     ✓  Allows different slots to run in parallel (correct — independent).
##     ✓  Handles "wait for spawn" naturally (processQueries awaits slot.ns.get).
##
## routeQuery() is the bridge: it dispatches synchronously to the right
## per-slot queue. There is no global request queue — routing IS the queue.
##
## WHERE THE DEPENDENCY ON NIMSUGGEST STATE IS HANDLED
## ════════════════════════════════════════════════════
## Your observation is correct: hover is just as dependent on nimsuggest
## being ready as didOpen is. processQueries handles this:
##
##   if slot.ns.isSome:
##     discard await slot.ns.get   # ← blocks until SPAWNING → READY
##
## A hover that arrives while nimsuggest is spawning waits here, in the
## queue, without the LSP handler needing to know. The dependency on
## nimsuggest state is satisfied by the queue layer, not by the handler.

import std/[options, tables]
import chronos
import ../langserver/[langserver_types, queue_types, queues, utils]
import ../nimsuggest/nimsuggest_types

# ─────────────────────────────────────────────────────────────────────────────
# Core routing primitive
# ─────────────────────────────────────────────────────────────────────────────

proc routeQuery*(
    ls: LanguageServer,
    uri: string,
    q: NimsuggestQuery,
): Future[seq[Suggest]] =
  ## Enqueue q to the slot that owns uri. SYNCHRONOUS — no await.
  ##
  ## Returns q.responseFuture. The caller (lsp.nim handler) awaits it.
  ## processQueries completes it when nimsuggest replies.
  ##
  ## If uri has no slot (file not open, or slot unassigned), the future is
  ## immediately completed with @[] so the caller gets a clean empty result.
  ##
  ## Atomicity guarantee (Chronos cooperative scheduler):
  ##   The table lookup and addLastNoWait are both synchronous. No other
  ##   coroutine can run between them. didClose cannot remove uri from
  ##   openFiles between the lookup and the enqueue.
  let fileInfo = ls.files.openFiles.getOrDefault(uri)
  if fileInfo == nil or fileInfo.slot == nil:
    q.responseFuture.complete(@[])
    return q.responseFuture
  fileInfo.slot.queryMailbox.addLastNoWait(q)
  q.responseFuture

# ─────────────────────────────────────────────────────────────────────────────
# Convenience constructors
#
# These exist so lsp.nim handlers do not need to construct NimsuggestQuery
# objects manually. Each proc matches one NimsuggestQueryKind.
# ─────────────────────────────────────────────────────────────────────────────

proc queryAt*(
    ls: LanguageServer,
    uri: string,
    kind: NimsuggestQueryKind,
    line, col: int,
): Future[seq[Suggest]] =
  ## Route a position-based query (hover, definition, completion, …).
  ## line is 1-based (nimsuggest convention); col is 0-based.
  ## The dirtyFile is resolved automatically from the stash.
  let q = NimsuggestQuery(
    kind: kind,
    uri: uri,
    dirtyFile: ls.uriToStash(uri),
    responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
    position: FilePosition(line: line, col: col),
  )
  ls.routeQuery(uri, q)

proc queryFile*(
    ls: LanguageServer,
    uri: string,
    kind: NimsuggestQueryKind,
): Future[seq[Suggest]] =
  ## Route a file-level query for kinds in the `discard` arm of NimsuggestQuery:
  ## CHECK_PROJECT, RECOMPILE, KNOWN, CHANGED.
  ##
  ## NOTE: DOCUMENT_SYMBOLS (outline) and CHECK_FILE are unfortunately in the
  ## `position` arm of the NimsuggestQuery discriminated union, even though
  ## those nimsuggest commands do not use the position. Use queryAt(uri, kind,
  ## 0, 0) for those until queue_types.nim is corrected to move them into the
  ## discard arm.
  let q = NimsuggestQuery(
    kind: kind,
    uri: uri,
    dirtyFile: ls.uriToStash(uri),
    responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
  )
  ls.routeQuery(uri, q)

proc queryInlayHints*(
    ls: LanguageServer,
    uri: string,
    startLine, startCol, endLine, endCol: int,
    hintOptions: string,
): Future[seq[Suggest]] =
  ## Route an inlay-hints query (needs a range, not a single position).
  let q = NimsuggestQuery(
    kind: NimsuggestQueryKind.INLAY_HINTS,
    uri: uri,
    dirtyFile: ls.uriToStash(uri),
    responseFuture: newFuture[seq[Suggest]]("inlayHints"),
    hintStart: FilePosition(line: startLine, col: startCol),
    hintEnd: FilePosition(line: endLine, col: endCol),
    hintOptions: hintOptions,
  )
  ls.routeQuery(uri, q)

proc queryExpand*(
    ls: LanguageServer,
    uri: string,
    line, col: int,
    tag: string = "",
): Future[seq[Suggest]] =
  ## Route a macro/ARC expansion query.
  ## tag is "" for expandAll (no level), or "  all" / "  N" for expand with level.
  let q = NimsuggestQuery(
    kind: NimsuggestQueryKind.EXPAND,
    uri: uri,
    dirtyFile: ls.uriToStash(uri),
    responseFuture: newFuture[seq[Suggest]]("expand"),
    position: FilePosition(line: line, col: col),
    expandTag: tag,
  )
  ls.routeQuery(uri, q)

proc queryWorkspaceSymbols*(
    ls: LanguageServer,
    uri: string,  ## any uri — used only to look up a live slot
    symbolQuery: string,
): Future[seq[Suggest]] =
  ## Route a workspace-symbol query. Uses any live slot because globalSymbols
  ## is not file-specific; the uri is just used to find a slot.
  let q = NimsuggestQuery(
    kind: NimsuggestQueryKind.WORKSPACE_SYMBOLS,
    uri: uri,
    dirtyFile: "",
    responseFuture: newFuture[seq[Suggest]]("workspaceSymbols"),
    symbolQuery: symbolQuery,
  )
  ls.routeQuery(uri, q)

# ─────────────────────────────────────────────────────────────────────────────
# EXAMPLE: how an lsp.nim handler looks before and after
#
# BEFORE (bypasses queue, holds raw NimSuggest handle):
#
#   proc hover*(ls, params, id): Future[Option[Hover]] {.async.} =
#     with (params.position, params.textDocument):
#       let nimsuggest = await ls.tryGetNimsuggest(uri)   # raw handle
#       if nimsuggest.isNone: return none(Hover)
#       let ch = ls.getCharacter(uri, line, character)
#       if ch.isNone: return none(Hover)
#       let suggestions = await nimsuggest.get().highlight( # direct TCP call
#         uriToPath(uri), ls.uriToStash(uri), line + 1, ch.get
#       )
#
# AFTER (routes through per-slot queue):
#
#   proc hover*(ls, params, id): Future[Option[Hover]] {.async.} =
#     with (params.position, params.textDocument):
#       let ch = ls.getCharacter(uri, line, character)
#       if ch.isNone: return none(Hover)
#       let suggestions = await ls.queryAt(            # enqueues, returns future
#         uri, NimsuggestQueryKind.HOVER, line + 1, ch.get
#       )
#       # processQueries waited for spawn, called highlight, and completed the future.
#       # The handler never touched NimSuggest or suggestapi.
# ─────────────────────────────────────────────────────────────────────────────
