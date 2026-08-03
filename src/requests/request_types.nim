## request_types.nim
##
## Types for every message that arrives from the LSP client.
##
## TWO-LAYER QUEUE DESIGN
## ══════════════════════
##
## Layer 1 — LSP routing  (this file + requests.nim)
##   routeQuery() translates LSP params into a NimsuggestQuery and enqueues it
##   to the correct slot's queryMailbox. This call is SYNCHRONOUS — it has no
##   `await` — so the slot lookup and the enqueue are atomic under Chronos's
##   cooperative scheduler. Nothing else can run between them.
##
##   This closes two race conditions:
##     a) didClose / hover race:  didClose removes uri from openFiles; hover
##        either sees the entry (and enqueues before didClose runs) or does not
##        (and returns @[] cleanly). No half-state is observable.
##     b) spawn / query race:     if nimsuggest is still spawning when hover
##        arrives, the query sits in the queryMailbox. processQueries awaits
##        slot.ns.get (see Layer 2) and dispatches only after the process is
##        ready. The handler just awaits responseFuture — it never needs to
##        know about the spawn state.
##
## Layer 2 — Per-slot dispatch  (queue_types.nim + queues.nim)
##   processQueries runs one coroutine per slot. It:
##     • awaits slot.ns.get until the process is READY
##     • dispatches the TCP call (sug / def / highlight / …)
##     • completes responseFuture with the result
##   Slots are independent: hover on file_a and hover on file_b run in
##   parallel on different slots. Queries for the SAME slot are serialized.
##
## WHAT lsp.nim HANDLERS DO
## ════════════════════════
## Every handler that needs nimsuggest now does:
##
##   let results = await ls.routeQuery(uri, NimsuggestQuery(
##     kind:           NimsuggestQueryKind.HOVER,
##     uri:            uri,
##     dirtyFile:      ls.uriToStash(uri),
##     responseFuture: newFuture[seq[Suggest]]("hover"),
##     position:       FilePosition(line: line + 1, col: col),
##   ))
##
## No handler ever holds a raw NimSuggest handle or calls suggestapi directly.
## All timeout, crash, and "wait for ready" logic lives in Layer 2.

import ../protocol/types

# ─────────────────────────────────────────────────────────────────────────────
# Text-document requests (client → server, response required)
# ─────────────────────────────────────────────────────────────────────────────

type
  TextDocumentRequestKind* {.pure.} = enum
    COMPLETION
    DEFINITION
    TYPE_DEFINITION
    DECLARATION
    DOCUMENT_SYMBOL
    HOVER
    REFERENCES
    PREPARE_RENAME
    RENAME
    INLAY_HINT
    SIGNATURE_HELP
    FORMATTING
    DOCUMENT_HIGHLIGHT
    CODE_ACTION

  TextDocumentRequest* = object
    case kind*: TextDocumentRequestKind
    of COMPLETION:
      completion*: CompletionParams
    of DEFINITION, DECLARATION, TYPE_DEFINITION, DOCUMENT_HIGHLIGHT:
      documentPositions*: TextDocumentPositionParams
    of DOCUMENT_SYMBOL:
      documentSymbol*: DocumentSymbolParams
    of HOVER:
      hover*: HoverParams
    of REFERENCES:
      references*: ReferenceParams
    of PREPARE_RENAME:
      prepareRename*: PrepareRenameParams
    of RENAME:
      rename*: RenameParams
    of INLAY_HINT:
      inlayHint*: InlayHintParams
    of SIGNATURE_HELP:
      signatureHelp*: SignatureHelpParams
    of FORMATTING:
      formatting*: DocumentFormattingParams
    of CODE_ACTION:
      codeAction*: CodeActionParams

# ─────────────────────────────────────────────────────────────────────────────
# Workspace requests
# ─────────────────────────────────────────────────────────────────────────────

type
  WorkspaceRequestKind* {.pure.} = enum
    EXECUTE_COMMAND
    SYMBOL

  WorkspaceRequest* = object
    case kind*: WorkspaceRequestKind
    of EXECUTE_COMMAND:
      executeCommand*: ExecuteCommandParams
    of SYMBOL:
      symbol*: WorkspaceSymbolParams

# ─────────────────────────────────────────────────────────────────────────────
# Extension requests  (nimlangserver-specific, not in the LSP spec)
# ─────────────────────────────────────────────────────────────────────────────

type
  ExtensionRequestKind* {.pure.} = enum
    MACRO_EXPANSION
    STATUS
    CAPABILITIES
    SUGGEST
    TASKS
    RUN_TASK
    LIST_TESTS
    RUN_TESTS
    CANCEL_TEST

  ExtensionRequest* = object
    ## Extension requests do not go through routeQuery — they are handled
    ## directly in lsp.nim. None of them need nimsuggest, so they do not
    ## need the serialization that routeQuery provides.
    case kind*: ExtensionRequestKind
    of MACRO_EXPANSION: discard  # handled by nimexpand.nim, not suggestapi
    of STATUS:          discard
    of CAPABILITIES:    discard
    of SUGGEST:         suggest*: SuggestParams
    of TASKS:           discard
    of RUN_TASK:        runTask*: RunTaskParams
    of LIST_TESTS:      discard
    of RUN_TESTS:       discard
    of CANCEL_TEST:     discard

# ─────────────────────────────────────────────────────────────────────────────
# Top-level request envelope
# ─────────────────────────────────────────────────────────────────────────────

type
  LanguageServerRequestKind* {.pure.} = enum
    INITIALIZE
    SHUTDOWN
    EXIT
    TEXT_DOCUMENT
    WORKSPACE
    EXTENSION

  LanguageServerRequest* = object
    requestID*: uint
      ## Maps to the id field in the JSON-RPC request.
      ## Needed by addProjectFileToPendingRequest and cancellation.
    case kind*: LanguageServerRequestKind
    of INITIALIZE:
      initialize*: LspInitializeParams
    of SHUTDOWN, EXIT:
      discard
    of TEXT_DOCUMENT:
      textDocument*: TextDocumentRequest
    of WORKSPACE:
      workspace*: WorkspaceRequest
    of EXTENSION:
      extension*: ExtensionRequest

# ─────────────────────────────────────────────────────────────────────────────
# Notifications (client → server, no response)
#
# Notifications mutate shared state in ls.files (openFiles table, stash
# files, slot ownership). They are processed directly by the handlers in
# files.nim and lsp.nim — no queue is needed because Chronos's cooperative
# scheduler makes each notification handler atomic between its own await
# points. A notification that mutates openFiles completes that mutation
# synchronously before yielding, so a concurrent query's routeQuery() call
# either sees the pre-mutation or post-mutation state, never a half-state.
# ─────────────────────────────────────────────────────────────────────────────

type
  TextDocumentNotificationKind* {.pure.} = enum
    DID_OPEN
    DID_CHANGE
    DID_SAVE
    DID_CLOSE
    WILL_SAVE_WAIT_UNTIL
    DID_RENAME_FILES
    DID_DELETE_FILES
    DID_CHANGE_CONFIGURATION

  TextDocumentNotification* = object
    case kind*: TextDocumentNotificationKind
    of DID_OPEN:
      didOpen*: DidOpenTextDocumentParams
    of DID_CHANGE:
      didChange*: DidChangeTextDocumentParams
    of DID_SAVE:
      didSave*: DidSaveTextDocumentParams
    of DID_CLOSE:
      didClose*: DidCloseTextDocumentParams
    of WILL_SAVE_WAIT_UNTIL:
      willSave*: WillSaveTextDocumentParams
    of DID_RENAME_FILES:
      renameFiles*: RenameFilesParams
    of DID_DELETE_FILES:
      deleteFiles*: DeleteFilesParams
    of DID_CHANGE_CONFIGURATION:
      discard  # params not needed; server re-requests config from client

type
  WorkspaceNotificationKind* {.pure.} = enum
    DID_RENAME_FILES
    DID_DELETE_FILES
    DID_CHANGE_CONFIGURATION

  WorkspaceNotification* = object
    case kind*: WorkspaceNotificationKind
    of DID_RENAME_FILES:
      renameFiles*: RenameFilesParams
    of DID_DELETE_FILES:
      deleteFiles*: DeleteFilesParams
    of DID_CHANGE_CONFIGURATION:
      discard

type
  LanguageServerNotificationKind* {.pure.} = enum
    INITIALIZED
    CANCEL_REQUEST
    SET_TRACE
    TEXT_DOCUMENT
    WORKSPACE

  LanguageServerNotification* = object
    case kind*: LanguageServerNotificationKind
    of INITIALIZED:
      discard
    of CANCEL_REQUEST:
      cancelRequest*: CancelParams
    of SET_TRACE:
      setTrace*: SetTraceParams
    of TEXT_DOCUMENT:
      textDocument*: TextDocumentNotification
    of WORKSPACE:
      workspace*: WorkspaceNotification

# ─────────────────────────────────────────────────────────────────────────────
# Top-level message envelope  (request or notification)
# ─────────────────────────────────────────────────────────────────────────────

type
  LanguageServerQueryKind* {.pure.} = enum
    REQUEST
    NOTIFICATION

  LanguageServerQuery* = object
    case kind*: LanguageServerQueryKind
    of REQUEST:
      request*: LanguageServerRequest
    of NOTIFICATION:
      notification*: LanguageServerNotification
