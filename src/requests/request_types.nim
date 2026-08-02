import ../protocol/types

type
  TextDocumentRequestKind* {.pure.} = enum
    COMPLETION, 
    DEFINITION, TYPE_DEFINITION,
    DECLARATION, 
    DOCUMENT_SYMBOL,
    HOVER,
    REFERENCES,
    PREPARE_RENAME,
    RENAME,
    INLAY_HINT,
    SIGNATURE_HELP,
    FORMATTING,
    DOCUMENT_HIGHLIGHT,
    CODE_ACTION

  TextDocumentRequest* = object
    case kind*: TextDocumentRequestKind
    of COMPLETION: 
      completion*: CompletionParams
    of DEFINITION, DECLARATION, TYPE_DEFINITION, DOCUMENT_HIGHLIGHT: 
      documentPositions*: TextDocumentPositionParams
    of DOCUMENT_SYMBOL: 
      documentSynbol*: DocumentSymbolParams
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

type
  WorkspaceRequestKind* {.pure.} = enum
    EXECUTE_COMMAND,
    SYMBOL,

  WorkspaceRequest* = object
    case kind*: WorkspaceRequestKind
    of EXECUTE_COMMAND: 
      executeCommand*: ExecuteCommandParams
    of SYMBOL: 
      symbol*: WorkspaceSymbolParams

type
  ExtensionRequestKind* {.pure.} = enum
    MACRO_EXPANSION,
    STATUS,
    CAPABILITIES,
    SUGGEST,
    TASKS,
    RUN_TASK, 
    LIST_TESTS,
    RUN_TESTS,
    CANCEL_TEST

  ExtensionRequest* = object
    case kind*: ExtensionRequestKind
    of MACRO_EXPANSION: discard
    of STATUS: discard
    of CAPABILITIES: discard
    of SUGGEST: discard
    of TASKS: discard
    of RUN_TASK: discard 
    of LIST_TESTS: discard
    of RUN_TESTS: discard
    of CANCEL_TEST: discard

type
  LanguageServerRequestKind* {.pure.} = enum
    INITIALIZE, SHUTDOWN, EXIT,
    TEXT_DOCUMENT, WORKSPACE, 
    EXTENSION

  LanguageServerRequest* = object
    requestID*: uint
    case kind*: LanguageServerRequestKind
    of INITIALIZE:
      initialize*: LspInitializeParams
    of SHUTDOWN, EXIT: discard
    of TEXT_DOCUMENT: 
      text_document*: TextDocumentRequest
    of WORKSPACE:
      workspace*: WorkspaceRequest
    of EXTENSION:
      extension*: ExtensionRequest

type
  TextDocumentNotificationKind* {.pure.} = enum
    DID_CHANGE, DID_CLOSE, DID_OPEN,
    DID_SAVE, WILL_SAVE_WAIT_UNTIL, 
    DID_RENAME_FILES,
    DID_DELETE_FILES,
    DID_CHANGE_CONFIGURATION

  TextDocumentNotification* = object
    case kind*: TextDocumentNotificationKind
    of DID_CHANGE: discard 
    of DID_CLOSE: discard 
    of DID_OPEN: discard 
    of DID_SAVE: discard 
    of WILL_SAVE_WAIT_UNTIL: discard 
    of DID_RENAME_FILES: discard 
    of DID_DELETE_FILES: discard 
    of DID_CHANGE_CONFIGURATION: discard 

type
  WorkspaceNotificationKind* {.pure.} = enum
    DID_RENAME_FILES, DID_DELETE_FILES, DID_CHANGE_CONFIGURATION  

  WorkspaceNotification* = object
    case kind*: WorkspaceNotificationKind
    of DID_RENAME_FILES: discard
    of DID_DELETE_FILES: discard
    of DID_CHANGE_CONFIGURATION: discard

type
  LanguageServerNotificationKind* {.pure.} = enum
    INITIALIZED, 
    CANCEL_REQUEST, SET_TRACE,
    TEXT_DOCUMENT, WORKSPACE

  LanguageServerNotification* = object
    case kind*: LanguageServerNotificationKind
    of INITIALIZED: discard
    of CANCEL_REQUEST: 
      cancelRequest*: CancelParams
    of SET_TRACE:
      setTrace*: SetTraceParams
    of TEXT_DOCUMENT: 
      textDocument*: TextDocumentNotification
    of WORKSPACE: 
      workspace*: WorkspaceNotification

type
  LanguageServerQueryKind* {.pure.} = enum
    REQUEST, NOTIFICATION

  LanguageServerQuery* = object
    case kind*: LanguageServerQueryKind
    of LanguageServerQueryKind.REQUEST:
      request*: LanguageServerRequest
    of LanguageServerQueryKind.NOTIFICATION:
      notification*: LanguageServerNotification
