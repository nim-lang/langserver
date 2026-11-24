{.push raises: [], gcsafe.}

import
  std/[hashes, options, paths, tables, uri],
  chronicles,
  json_rpc/router,
  json_serialization,
  json_serialization/std/[options as jsoptions, tables as jstables],
  ./[oneof, extends]

export
  json_serialization, jsoptions, jstables, paths, uri, RequestId, RequestIdKind, Null

# Spec:
# https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/

type
  # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentUri
  LspUri* = distinct string
  DocumentUri* = LspUri

proc `$`*(x: LspUri): string {.borrow.}
proc `==`*(a, b: LspUri): bool {.borrow.}
proc hash*(x: LspUri): Hash {.borrow.}
chronicles.formatIt(LspUri):
  $it
chronicles.formatIt(Path):
  $it

proc len*(x: Path): int =
  x.string.len

# https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#uinteger
type uinteger* = distinct int

const uintegerHigh* = uinteger(int32.high)

extendTypes:
  type
    OptionalSeq*[T] = Option[seq[T]]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#lspAny
    LspAny* = JsonString

    NullableKind* = enum
      nkNull
      nkValue

    Nullable*[T] = object
      case kind*: NullableKind
      of nkNull:
        null*: Null
      of nkValue:
        value*: T

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#cancelRequest
    CancelParams* = object
      id*: RequestId

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#position
    Position* = object
      line*: uinteger
      character*: uinteger

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#range
    Range* = object
      start*: Position
      `end`*: Position

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#location
    Location* = object
      uri*: DocumentUri
      `range`*: Range

    DiagnosticCodeKind* = enum
      dgcNum
      dgcStr

    DiagnosticCode* = object
      case kind*: DiagnosticCodeKind
      of dgcNum:
        num*: int
      of dgcStr:
        str*: string

    DiagnosticMessageKind* = enum
      dmStr
      dmMarkup

    DiagnosticMessage* = object
      case kind*: DiagnosticMessageKind
      of dmStr:
        str*: string
      of dmMarkup:
        markup*: MarkupContent

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#diagnostic
    Diagnostic* = object
      `range`*: Range
      severity*: Option[int]
      code*: Option[DiagnosticCode]
      source*: Option[string]
      message*: DiagnosticMessage

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#command
    Command* = object
      title*: string
      command*: string
      arguments*: OptionalSeq[LspAny]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeAction
    CodeAction* = object
      command*: Option[Command]
      title*: string
      kind*: Option[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textEdit
    TextEdit* = object
      `range`*: Range
      newText*: string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceEdit
    WorkspaceEdit* = object
      changes*: Option[Table[DocumentUri, seq[TextEdit]]]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentIdentifier
    TextDocumentIdentifier* = object
      uri*: DocumentUri

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentItem
    TextDocumentItem* = object
      uri*: DocumentUri
      languageId*: string
      version*: int
      text*: string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#versionedTextDocumentIdentifier
    VersionedTextDocumentIdentifier* {.extends: [TextDocumentIdentifier].} = object
      version*: int

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentPositionParams
    TextDocumentPositionParams* = object
      textDocument*: TextDocumentIdentifier
      position*: Position

    ExpandTextDocumentPositionParams* {.extends: [TextDocumentPositionParams].} = object
      level*: Option[int]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentFilter
    DocumentFilter* = object
      pattern*: Option[GlobPattern]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#markupContent
    MarkupContent* = object
      kind*: string
      value*: string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initializeParams
    # note processId is required but we don't use it;
    # rootUri is required but deprecated, so made optional
    InitializeParams* {.extends: [WorkDoneProgressParams].} = object
      # processId*: Nullable[int]
      rootPath*: Option[string]
      rootUri*: Option[DocumentUri]
      capabilities*: ClientCapabilities
      workspaceFolders*: OptionalSeq[WorkspaceFolder]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#setTrace
    SetTraceParams* = object
      value*: string

    ProgressTokenKind* = enum
      ptNum
      ptStr

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#progress
    ProgressToken* = object
      case kind*: ProgressTokenKind
      of ptNum:
        num*: int
      of ptStr:
        str*: string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workDoneProgressParams
    WorkDoneProgressParams* = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#partialResultParams
    PartialResultParams* = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workDoneProgressOptions
    WorkDoneProgressOptions* = object
      workDoneProgress*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workDoneProgressBegin
    WorkDoneProgressBegin* = object
      kind*: string
      title*: string
      message*: Option[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workDoneProgressEnd
    WorkDoneProgressEnd* = object
      kind*: string
      message*: Option[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#progress
    ProgressParams*[T] = object
      token*: ProgressToken
      value*: T

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_workDoneProgress_create
    WorkDoneProgressCreateParams* = object
      token*: ProgressToken

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#configurationItem
    ConfigurationItem* = object
      section*: Option[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#configurationParams
    ConfigurationParams* = object
      items*: seq[ConfigurationItem]

    # 'create' | 'rename' | 'delete'
    ResourceOperationKind = string

    # 'abort' | 'transactional' | 'undo' | 'textOnlyTransactional'
    FailureHandlingKind = string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#didChangeConfigurationClientCapabilities
    DidChangeConfigurationClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#didChangeWatchedFilesClientCapabilities
    DidChangeWatchedFilesClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#executeCommandClientCapabilities
    ExecuteCommandClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlayHintWorkspaceClientCapabilities
    InlayHintWorkspaceClientCapabilities* = object
      refreshSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#diagnosticWorkspaceClientCapabilities
    DiagnosticWorkspaceClientCapabilities* = object
      refreshSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceClientCapabilities
    WorkspaceClientCapabilities* = object
      didChangeConfiguration*: Option[DidChangeConfigurationClientCapabilities]
      didChangeWatchedFiles*: Option[DidChangeWatchedFilesClientCapabilities]
      executeCommand*: Option[ExecuteCommandClientCapabilities]
      workspaceFolders*: Option[bool]
      configuration*: Option[bool]
      inlayHint*: Option[InlayHintWorkspaceClientCapabilities]
      diagnostics*: Option[DiagnosticWorkspaceClientCapabilities]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionClientCapabilities
    CompletionClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      contextSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#hoverClientCapabilities
    HoverClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#signatureHelpClientCapabilities
    SignatureHelpClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      contextSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#referenceClientCapabilities
    ReferenceClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentHighlightClientCapabilities
    DocumentHighlightClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentFormattingClientCapabilities
    DocumentFormattingClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#definitionClientCapabilities
    DefinitionClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#typeDefinitionClientCapabilities
    TypeDefinitionClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeActionClientCapabilities
    CodeActionClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#renameClientCapabilities
    RenameClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      prepareSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#declarationClientCapabilities
    DeclarationClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlayHintClientCapabilities
    InlayHintClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentClientCapabilities
    TextDocumentClientCapabilities* = object
      completion*: Option[CompletionClientCapabilities]
      hover*: Option[HoverClientCapabilities]
      signatureHelp*: Option[SignatureHelpClientCapabilities]
      declaration*: Option[DeclarationClientCapabilities]
      definition*: Option[DefinitionClientCapabilities]
      typeDefinition*: Option[TypeDefinitionClientCapabilities]
      references*: Option[ReferenceClientCapabilities]
      documentHighlight*: Option[DocumentHighlightClientCapabilities]
      codeAction*: Option[CodeActionClientCapabilities]
      formatting*: Option[DocumentFormattingClientCapabilities]
      rename*: Option[RenameClientCapabilities]
      inlayHint*: Option[InlayHintClientCapabilities]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_showMessageRequest
    ShowMessageRequestClientCapabilities* = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#windowClientCapabilities
    WindowClientCapabilities* = object
      workDoneProgress*: Option[bool]
      showMessage*: Option[ShowMessageRequestClientCapabilities]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientCapabilities
    ClientCapabilities* = object
      workspace*: Option[WorkspaceClientCapabilities]
      textDocument*: Option[TextDocumentClientCapabilities]
      window*: Option[WindowClientCapabilities]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceFolder
    WorkspaceFolder* = object
      uri*: LspUri
      name*: string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initializeResult
    InitializeResult* = object
      capabilities*: ServerCapabilities

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionOptions
    CompletionOptions* {.extends: [WorkDoneProgressOptions].} = object
      resolveProvider*: Option[bool]
      triggerCharacters*: OptionalSeq[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#signatureHelpOptions
    SignatureHelpOptions* {.extends: [WorkDoneProgressOptions].} = object
      triggerCharacters*: OptionalSeq[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#executeCommandOptions
    ExecuteCommandOptions* {.extends: [WorkDoneProgressOptions].} = object
      commands*: seq[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#saveOptions
    SaveOptions* = object
      includeText*: Option[bool]

    TextDocumentSyncOptionsSaveKind* = enum
      tdsosBool
      tdsosOptions

    TextDocumentSyncOptionsSave* = object
      case kind*: TextDocumentSyncOptionsSaveKind
      of tdsosBool:
        boolean*: bool
      of tdsosOptions:
        options*: SaveOptions

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentSyncOptions
    TextDocumentSyncOptions* = object
      openClose*: Option[bool]
      change*: Option[int]
      willSave*: Option[bool]
      willSaveWaitUntil*: Option[bool]
      save*: Option[TextDocumentSyncOptionsSave]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#staticRegistrationOptions
    StaticRegistrationOptions* = object
      id*: Option[string]

    WorkspaceFoldersChangeNotificationsKind* = enum
      wfcnStr
      wfcnBool

    WorkspaceFoldersChangeNotifications* = object
      case kind*: WorkspaceFoldersChangeNotificationsKind
      of wfcnStr:
        str*: string
      of wfcnBool:
        boolean*: bool

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceFoldersServerCapabilities
    WorkspaceFoldersServerCapabilities* = object
      supported*: Option[bool]
      changeNotifications*: Option[WorkspaceFoldersChangeNotifications]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#fileOperationOptions
    FileOperationOptions* = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceOptions
    WorkspaceOptions* = object
      workspaceFolders*: Option[WorkspaceFoldersServerCapabilities]
      #!!!!!!!fileOperations*: Option[FileOperationOptions]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentSelector
    DocumentSelector* = seq[DocumentFilter]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentRegistrationOptions
    TextDocumentRegistrationOptions* = object
      documentSelector*: Nullable[DocumentSelector]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#renameOptions
    RenameOptions* {.extends: [WorkDoneProgressOptions].} = object
      prepareProvider*: Option[bool]

    ServerCapabilitiesTextDocumentSyncKind* = enum
      stdsOptions
      stdsKind

    ServerCapabilitiesTextDocumentSync* = object
      case kind*: ServerCapabilitiesTextDocumentSyncKind
      of stdsOptions:
        options*: TextDocumentSyncOptions
      of stdsKind:
        syncKind*: int

    ServerCapabilitiesInlayHintProviderKind* = enum
      sihpBool
      sihpOptions
      sihpRegistration

    ServerCapabilitiesInlayHintProvider* = object
      case kind*: ServerCapabilitiesInlayHintProviderKind
      of sihpBool:
        boolean*: bool
      of sihpOptions:
        options*: InlayHintOptions
      of sihpRegistration:
        registration*: InlayHintRegistrationOptions

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlayHintRegistrationOptions
    InlayHintRegistrationOptions* {.
      extends:
        [InlayHintOptions, TextDocumentRegistrationOptions, StaticRegistrationOptions]
    .} = object

    ServerCapabilitiesRenameProviderKind* = enum
      srpBool
      srpOptions

    ServerCapabilitiesRenameProvider* = object
      case kind*: ServerCapabilitiesRenameProviderKind
      of srpBool:
        boolean*: bool
      of srpOptions:
        options*: RenameOptions

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlayHintOptions
    InlayHintOptions* {.extends: [WorkDoneProgressOptions].} = object
      resolveProvider*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#serverCapabilities
    ServerCapabilities* = object #!!!positionEncoding*: Option[string]
      textDocumentSync*: Option[ServerCapabilitiesTextDocumentSync]
      completionProvider*: Option[CompletionOptions]
      hoverProvider*: Option[bool]
      signatureHelpProvider*: Option[SignatureHelpOptions]
      declarationProvider*: Option[bool]
      definitionProvider*: Option[bool]
      typeDefinitionProvider*: Option[bool]
      referencesProvider*: Option[bool]
      documentHighlightProvider*: Option[bool]
      documentSymbolProvider*: Option[bool]
      workspaceSymbolProvider*: Option[bool]
      codeActionProvider*: Option[bool]
      documentFormattingProvider*: Option[bool]
      renameProvider*: Option[ServerCapabilitiesRenameProvider]
      executeCommandProvider*: Option[ExecuteCommandOptions]
      inlayHintProvider*: Option[ServerCapabilitiesInlayHintProvider]
      workspace*: Option[WorkspaceOptions]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initialized
    InitializedParams* = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_showMessage
    ShowMessageParams* = object
      `type`*: int
      message*: string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#registration
    Registration* = object
      id*: string
      `method`*: string
      registerOptions*: Option[LspAny]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#registrationParams
    RegistrationParams* = object
      registrations*: seq[Registration]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceFoldersChangeEvent
    WorkspaceFoldersChangeEvent* = object
      added*: seq[WorkspaceFolder]
      removed*: seq[WorkspaceFolder]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#didChangeWorkspaceFoldersParams
    DidChangeWorkspaceFoldersParams* = object
      event*: WorkspaceFoldersChangeEvent

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#didChangeConfigurationParams
    DidChangeConfigurationParams* = object
      settings*: LspAny

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#fileEvent
    FileEvent* = object
      uri*: DocumentUri
      `type`*: int

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#didChangeWatchedFilesParams
    DidChangeWatchedFilesParams* = object
      changes*: seq[FileEvent]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#didChangeWatchedFilesRegistrationOptions
    DidChangeWatchedFilesRegistrationOptions* = object
      watchers*: seq[FileSystemWatcher]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#pattern
    Pattern* = string

    RelativePatternBaseUriKind* = enum
      rpbuFolder
      rpbuUri

    RelativePatternBaseUri* = object
      case kind*: RelativePatternBaseUriKind
      of rpbuFolder:
        folder*: WorkspaceFolder
      of rpbuUri:
        uri*: LspUri

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#relativePattern
    RelativePattern* = object
      baseUri*: RelativePatternBaseUri
      pattern*: Pattern

    GlobPatternKind* = enum
      gpPattern
      gpRelative

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#globPattern
    GlobPattern* = object
      case kind*: GlobPatternKind
      of gpPattern:
        pattern*: Pattern
      of gpRelative:
        relative*: RelativePattern

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#fileSystemWatcher
    FileSystemWatcher* = object
      globPattern*: GlobPattern
      kind*: Option[int]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceSymbolParams
    WorkspaceSymbolParams* {.extends: [WorkDoneProgressParams, PartialResultParams].} = object
      query*: string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#executeCommandParams
    ExecuteCommandParams* {.extends: [WorkDoneProgressParams].} = object
      command*: string
      arguments*: OptionalSeq[LspAny]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#applyWorkspaceEditParams
    ApplyWorkspaceEditParams* = object
      label*: Option[string]
      edit*: WorkspaceEdit

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#applyWorkspaceEditResult
    ApplyWorkspaceEditResult* = object
      applied*: bool

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#didOpenTextDocumentParams
    DidOpenTextDocumentParams* = object
      textDocument*: TextDocumentItem

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#didChangeTextDocumentParams
    DidChangeTextDocumentParams* = object
      textDocument*: VersionedTextDocumentIdentifier
      contentChanges*: seq[TextDocumentContentChangeEvent]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentContentChangeEvent
    TextDocumentContentChangeEvent* = object
      range*: Option[Range]
      text*: string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#willSaveTextDocumentParams
    WillSaveTextDocumentParams* = object
      textDocument*: TextDocumentIdentifier
      reason*: int

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#didSaveTextDocumentParams
    DidSaveTextDocumentParams* = object
      textDocument*: TextDocumentIdentifier
      text*: Option[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#didCloseTextDocumentParams
    DidCloseTextDocumentParams* = object
      textDocument*: TextDocumentIdentifier

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#publishDiagnosticsParams
    PublishDiagnosticsParams* = object
      uri*: DocumentUri
      diagnostics*: seq[Diagnostic]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionParams
    CompletionParams* {.
      extends: [TextDocumentPositionParams, WorkDoneProgressParams, PartialResultParams]
    .} = object
      context*: Option[CompletionContext]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionContext
    CompletionContext* = object
      triggerKind*: int

    CompletionItemDocumentationKind* = enum
      cidStr
      cidMarkup

    CompletionItemDocumentation* = object
      case kind*: CompletionItemDocumentationKind
      of cidStr:
        str*: string
      of cidMarkup:
        markup*: MarkupContent

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionItem
    CompletionItem* = object
      label*: string
      kind*: Option[int]
      detail*: Option[string]
      documentation*: Option[CompletionItemDocumentation]
      command*: Option[Command]
      data*: Option[LspAny]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#markedString
    MarkedStringOption* = object
      language*: string
      value*: string

    MarkedStringKind* = enum
      msStr
      msOption

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#markedString
    MarkedString* = object
      case kind*: MarkedStringKind
      of msStr:
        str*: string
      of msOption:
        option*: MarkedStringOption

    HoverContentsKind* = enum
      hcMarkedString
      hcMarkedStrings
      hcMarkup

    HoverContents* = object
      case kind*: HoverContentsKind
      of hcMarkedString:
        markedString*: MarkedString
      of hcMarkedStrings:
        markedStrings*: seq[MarkedString]
      of hcMarkup:
        markup*: MarkupContent

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#hover
    Hover* = object
      contents*: HoverContents
      range*: Option[Range]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#hoverParams
    HoverParams* {.extends: [TextDocumentPositionParams, WorkDoneProgressParams].} = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#signatureHelp
    SignatureHelp* = object
      signatures*: seq[SignatureInformation]
      activeSignature*: Option[uinteger]
      activeParameter*: Option[uinteger]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#signatureInformation
    SignatureInformation* = object
      label*: string
      # documentation*: Option[string]
      parameters*: OptionalSeq[ParameterInformation]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#parameterInformation
    ParameterInformationLabelKind* = enum
      pilStr
      pilOffsets

    ParameterInformationLabel* = object
      case kind*: ParameterInformationLabelKind
      of pilStr:
        str*: string
      of pilOffsets:
        offsets*: array[2, uinteger]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#parameterInformation
    ParameterInformation* = object
      label*: ParameterInformationLabel

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#referenceParams
    ReferenceParams* {.
      extends: [TextDocumentPositionParams, WorkDoneProgressParams, PartialResultParams]
    .} = object
      context*: ReferenceContext

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#referenceContext
    ReferenceContext* = object
      includeDeclaration*: bool

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentHighlight
    DocumentHighlight* = object
      `range`*: Range
      kind*: Option[int]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentSymbolParams
    DocumentSymbolParams* {.extends: [WorkDoneProgressParams, PartialResultParams].} = object
      textDocument*: TextDocumentIdentifier

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#symbolInformation
    SymbolInformation* = object
      name*: string
      kind*: int
      location*: Location

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeActionParams
    CodeActionParams* {.extends: [WorkDoneProgressParams, PartialResultParams].} = object
      textDocument*: TextDocumentIdentifier
      `range`*: Range
      context*: CodeActionContext

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeActionContext
    CodeActionContext* = object
      diagnostics*: seq[Diagnostic]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#formattingOptions
    FormattingOptions* = object
      tabSize*: uinteger
      insertSpaces*: bool

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentFormattingParams
    DocumentFormattingParams* {.extends: [WorkDoneProgressParams].} = object
      textDocument*: TextDocumentIdentifier
      options*: FormattingOptions

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#renameParams
    RenameParams* {.extends: [TextDocumentPositionParams, WorkDoneProgressParams].} = object
      newName*: string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#prepareRenameParams
    PrepareRenameParams* {.
      extends: [TextDocumentPositionParams, WorkDoneProgressParams]
    .} = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#signatureHelpContext
    SignatureHelpContext* = object
      triggerKind*: int
      isRetrigger*: bool
      activeSignatureHelp*: Option[SignatureHelp]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#signatureHelpParams
    SignatureHelpParams* {.
      extends: [TextDocumentPositionParams, WorkDoneProgressParams]
    .} = object
      context*: Option[SignatureHelpContext]

    ExpandResult* = object
      range*: Range
      content*: string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlayHintParams
    InlayHintParams* {.extends: [WorkDoneProgressParams].} = object
      textDocument*: TextDocumentIdentifier
      range*: Range

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlayHint
    InlayHintTooltipKind* = enum
      ihtStr
      ihtMarkup

    InlayHintTooltip* = object
      case kind*: InlayHintTooltipKind
      of ihtStr:
        str*: string
      of ihtMarkup:
        markup*: MarkupContent

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlayHintLabelPart
    InlayHintLabelPart* = object
      value*: string
      tooltip*: Option[InlayHintTooltip]
      location*: Option[Location]
      command*: Option[Command]

    InlayHintLabelKind* = enum
      ihlStr
      ihlParts

    InlayHintLabel* = object
      case kind*: InlayHintLabelKind
      of ihlStr:
        str*: string
      of ihlParts:
        parts*: seq[InlayHintLabelPart]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlayHint
    InlayHint* = object
      position*: Position
      label*: InlayHintLabel
      kind*: Option[int]
      textEdits*: OptionalSeq[TextEdit]
      tooltip*: Option[InlayHintTooltip]
      paddingLeft*: Option[bool]
      paddingRight*: Option[bool] #data*: OptionalNode

    NimsuggestCapability* = enum
      nsCon = "con"
      nsExceptionInlayHints = "exceptionInlayHints"
      nsUnknownFile = "unknownFile"
      nsMaxMemory = "maxMemory"
      nsOutline2 = "outline2"

    PendingRequestStatus* = object
      name*: string
      projectFile*: string
      time*: string
      state*: string

    NimsuggestStatus* = object
      projectFile*: string
      capabilities*: seq[NimsuggestCapability]
      version*: string
      path*: string
      port*: int
      openFiles*: seq[string]
      unknownFiles*: seq[string]

    LspExtensionCapability* = enum
      #List of extensions this server support. Useful for clients
      excRestartSuggest = "RestartSuggest"
      excNimbleTask = "NimbleTask"
      excRunTests = "RunTests"

    ProjectError* = object
      projectFile*: string
      errorMessage*: string
      lastKnownCmd*: string

    NimLangServerStatus* = object
      lspPath*: string
      version*: string
      nimsuggestInstances*: seq[NimsuggestStatus]
      openFiles*: seq[string]
      extensionCapabilities*: seq[LspExtensionCapability]
      pendingRequests*: seq[PendingRequestStatus]
      projectErrors*: seq[ProjectError]

    NimLangServerStatusParams* = object

    NimLangServerCapabilitiesParams* = object

    SuggestAction* = enum
      saNone = "none"
      saRestart = "restart"
      saRestartAll = "restartAll"

    SuggestParams* = object
      action*: SuggestAction
      projectFile*: string #Absolute path to file

    SuggestResult* = object
      actionPerformed*: SuggestAction

    NimbleTask* = object
      name*: string
      description*: string

    RunTaskParams* = object
      command*: seq[string] #command and args

    RunTaskResult* = object
      command*: seq[string] #command and args
      output*: seq[string] #output lines

    TestInfo* = object
      name*: string
      line*: int
      file*: string

    TestSuiteInfo* = object
      name*: string #The suite name, empty if it's a global test
      tests*: seq[TestInfo]

    TestProjectInfo* = object
      entryPoint*: string
      suites*: Table[string, TestSuiteInfo]
      error*: Option[string]

    ListTestsParams* = object
      entryPoint*: string
        #can be patterns? if empty we could do the same as nimble does or just run `nimble test args`

    ListTestsResult* = object
      projectInfo*: TestProjectInfo

    RunTestResult* = object
      name*: string
      time*: float
      failure*: Option[string]

    RunTestSuiteResult* = object
      name*: string
      tests*: int
      failures*: int
      errors*: int
      skipped*: int
      time*: float
      testResults*: seq[RunTestResult]

    RunTestParams* = object
      entryPoint*: string
      suiteName*: Option[string]
        #Optional, if provided, only run tests in the suite. Takes precedence over testName
      testNames*: Option[seq[string]] #Optional, if provided, only run the specific tests

    RunTestProjectResult* = object
      suites*: seq[RunTestSuiteResult]
      fullOutput*: string

    CancelTestResult* = object
      cancelled*: bool

    # https://github.com/modelcontextprotocol/modelcontextprotocol/blob/c4c367f9f58296a7053f5c78a52fd02bfbb56a49/schema/2025-11-25/schema.ts#L73
    McpNotificationParams* = object

    # https://github.com/modelcontextprotocol/modelcontextprotocol/blob/c4c367f9f58296a7053f5c78a52fd02bfbb56a49/schema/2025-11-25/schema.ts#L51
    McpRequestParams* = object

    # https://github.com/modelcontextprotocol/modelcontextprotocol/blob/c4c367f9f58296a7053f5c78a52fd02bfbb56a49/schema/2025-11-25/schema.ts#L35
    McpTaskAugmentedRequestParams* {.extends: [McpRequestParams].} = object

    # https://github.com/modelcontextprotocol/modelcontextprotocol/blob/c4c367f9f58296a7053f5c78a52fd02bfbb56a49/schema/2025-11-25/schema.ts#L627
    McpPaginatedRequestParams* {.extends: [McpRequestParams].} = object

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#calltoolrequestparams
    McpCallToolRequestParams* {.extends: [McpTaskAugmentedRequestParams].} = object
      name*: string
      arguments*: Option[JsonString]

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#result
    McpResult* = object

    # https://github.com/modelcontextprotocol/modelcontextprotocol/blob/c4c367f9f58296a7053f5c78a52fd02bfbb56a49/schema/2025-11-25/schema.ts#L641
    McpPaginatedResult* {.extends: [McpResult].} = object

    # https://github.com/modelcontextprotocol/modelcontextprotocol/blob/c4c367f9f58296a7053f5c78a52fd02bfbb56a49/schema/2025-11-25/schema.ts#L508
    McpIcons* = object

    # https://github.com/modelcontextprotocol/modelcontextprotocol/blob/c4c367f9f58296a7053f5c78a52fd02bfbb56a49/schema/2025-11-25/schema.ts#L528
    McpBaseMetadata* = object
      name*: string
      title*: Option[string]

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#implementation
    McpImplementation* {.extends: [McpBaseMetadata, McpIcons].} = object
      version*: string
      description*: Option[string]

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#initializerequestparams
    McpInitializeRequestParams* {.extends: [McpRequestParams].} = object
      protocolVersion*: string
      capabilities*: McpClientCapabilities
      clientInfo*: McpImplementation

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#clientcapabilities
    McpClientCapabilities* = object

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#initializeresult
    McpInitializeResult* {.extends: [McpResult].} = object
      protocolVersion*: string
      capabilities*: McpServerCapabilities
      serverInfo*: McpImplementation

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#tool
    McpToolSchema* = object
      `type`*: string
      properties*: Option[OrderedTable[string, JsonString]]
      required*: Option[seq[string]]

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#tool
    McpTool* {.extends: [McpBaseMetadata, McpIcons].} = object
      description*: Option[string]
      inputSchema*: McpToolSchema
      outputSchema*: Option[McpToolSchema]

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#listtoolsresult
    McpListToolsResult* {.extends: [McpPaginatedResult].} = object
      tools*: seq[McpTool]

    McpContentBlockType* = enum
      TextContent = "text"

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#contentblock
    McpContentBlock* = object
      case `type`*: McpContentBlockType
      of TextContent:
        text*: string

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#calltoolresult
    McpCallToolResult* {.extends: [McpResult].} = object
      content*: seq[McpContentBlock]
      structuredContent*: Option[JsonString]
      isError*: Option[bool]

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#servercapabilities
    McpToolsOptions* = object

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#servercapabilities
    McpServerCapabilities* = object
      tools*: Option[McpToolsOptions]

createJsonFlavor LspJson,
  automaticObjectSerialization = false,
  requireAllFields = true,
  omitOptionalFields = true,
  allowUnknownFields = true,
  skipNullFields = false

proc parseFileUri*(uri: LspUri): Uri {.raises: [UriParseError].} =
  result = parseUri(uri.string)
  if result.scheme != "file":
    let msg =
      "Invalid scheme in uri `" & uri.string & "`: " & result.scheme &
      ", only `file` is supported"
    raise (ref UriParseError)(msg: msg)
  elif result.hostname != "":
    let msg =
      "Invalid hostname in uri `" & uri.string & "`: " & result.hostname &
      ", only empty hostname is supported"
    raise (ref UriParseError)(msg: msg)

proc writeValue*(w: var JsonWriter[LspJson], x: LspUri) {.raises: [IOError].} =
  w.writeValue(x.string)

proc readValue*(
    r: var JsonReader[LspJson], x: var LspUri
) {.raises: [IOError, SerializationError].} =
  let uri = r.readValue(string)
  try:
    discard parseFileUri(LspUri(uri))
  except UriParseError as exc:
    r.raiseUnexpectedValue(exc.msg)
  x = LspUri(uri)

proc readValue*(
    r: var JsonReader[LspJson], x: var RequestId
) {.raises: [IOError, SerializationError].} =
  case r.tokKind
  of JsonValueKind.Number:
    x = RequestId(kind: riNumber, num: r.readValue(int))
  of JsonValueKind.String:
    x = RequestId(kind: riString, str: r.readValue(string))
  else:
    r.raiseUnexpectedValue("expected an integer or a string id")

proc writeValue*(w: var JsonWriter[LspJson], x: uinteger) {.raises: [IOError].} =
  w.writeValue(x.int)

proc readValue*(
    r: var JsonReader[LspJson], x: var uinteger
) {.raises: [IOError, SerializationError].} =
  let n = r.readValue(int)
  if n notin 0 .. uintegerHigh.int:
    r.raiseUnexpectedValue("uinteger out of range: " & $n)
  x = uinteger(n)

proc readValue*[T](
    r: var JsonReader[LspJson], x: var Nullable[T]
) {.raises: [IOError, SerializationError].} =
  if r.tokKind == JsonValueKind.Null:
    r.parseNull()
    x = Nullable[T](kind: nkNull)
  else:
    x = Nullable[T](kind: nkValue, value: r.readValue(T))

proc writeValue*[T](w: var JsonWriter[LspJson], x: Nullable[T]) {.raises: [IOError].} =
  case x.kind
  of nkNull:
    w.writeValue(JsonString("null"))
  of nkValue:
    w.writeValue(x.value)

LspJson.useOneOfSerializationFor(DiagnosticCode)
LspJson.useDefaultSerializationFor(MarkupContent)
LspJson.useOneOfSerializationFor(DiagnosticMessage)
LspJson.useOneOfSerializationFor(ParameterInformationLabel)
LspJson.useOneOfSerializationFor(ProgressToken)
LspJson.useOneOfSerializationFor(WorkspaceFoldersChangeNotifications)

LspJson.useDefaultSerializationFor(Position)
LspJson.useDefaultSerializationFor(Range)
LspJson.useDefaultSerializationFor(Location)
LspJson.useDefaultSerializationFor(Diagnostic)
LspJson.useDefaultSerializationFor(SignatureHelp)
LspJson.useDefaultSerializationFor(SignatureInformation)
LspJson.useDefaultSerializationFor(ParameterInformation)

LspJson.useDefaultReaderFor(CancelParams)
LspJson.useDefaultReaderFor(TextDocumentIdentifier)
LspJson.useDefaultReaderFor(VersionedTextDocumentIdentifier)
LspJson.useDefaultReaderFor(TextDocumentItem)
LspJson.useDefaultReaderFor(TextDocumentPositionParams)
LspJson.useDefaultReaderFor(ExpandTextDocumentPositionParams)
LspJson.useDefaultReaderFor(McpNotificationParams)
LspJson.useDefaultReaderFor(McpPaginatedRequestParams)
LspJson.useDefaultReaderFor(McpCallToolRequestParams)
LspJson.useDefaultReaderFor(McpImplementation)
LspJson.useDefaultReaderFor(McpInitializeRequestParams)
LspJson.useDefaultReaderFor(InitializeParams)
LspJson.useDefaultReaderFor(InitializedParams)
LspJson.useDefaultReaderFor(SetTraceParams)
LspJson.useDefaultReaderFor(DidChangeConfigurationClientCapabilities)
LspJson.useDefaultReaderFor(DidChangeWatchedFilesClientCapabilities)
LspJson.useDefaultReaderFor(ExecuteCommandClientCapabilities)
LspJson.useDefaultReaderFor(InlayHintWorkspaceClientCapabilities)
LspJson.useDefaultReaderFor(DiagnosticWorkspaceClientCapabilities)
LspJson.useDefaultReaderFor(WorkspaceClientCapabilities)
LspJson.useDefaultReaderFor(CompletionClientCapabilities)
LspJson.useDefaultReaderFor(HoverClientCapabilities)
LspJson.useDefaultReaderFor(SignatureHelpClientCapabilities)
LspJson.useDefaultReaderFor(ReferenceClientCapabilities)
LspJson.useDefaultReaderFor(DocumentHighlightClientCapabilities)
LspJson.useDefaultReaderFor(DocumentFormattingClientCapabilities)
LspJson.useDefaultReaderFor(DefinitionClientCapabilities)
LspJson.useDefaultReaderFor(TypeDefinitionClientCapabilities)
LspJson.useDefaultReaderFor(CodeActionClientCapabilities)
LspJson.useDefaultReaderFor(RenameClientCapabilities)
LspJson.useDefaultReaderFor(DeclarationClientCapabilities)
LspJson.useDefaultReaderFor(InlayHintClientCapabilities)
LspJson.useDefaultReaderFor(TextDocumentClientCapabilities)
LspJson.useDefaultReaderFor(ShowMessageRequestClientCapabilities)
LspJson.useDefaultReaderFor(WindowClientCapabilities)
LspJson.useDefaultReaderFor(McpClientCapabilities)
LspJson.useDefaultReaderFor(ClientCapabilities)
LspJson.useDefaultReaderFor(WorkspaceFolder)
LspJson.useDefaultReaderFor(WorkspaceSymbolParams)
LspJson.useDefaultReaderFor(ExecuteCommandParams)
LspJson.useDefaultReaderFor(DidOpenTextDocumentParams)
LspJson.useDefaultReaderFor(DidChangeTextDocumentParams)
LspJson.useDefaultReaderFor(TextDocumentContentChangeEvent)
LspJson.useDefaultReaderFor(WillSaveTextDocumentParams)
LspJson.useDefaultReaderFor(DidSaveTextDocumentParams)
LspJson.useDefaultReaderFor(DidCloseTextDocumentParams)
LspJson.useDefaultReaderFor(DidChangeWatchedFilesParams)
LspJson.useDefaultReaderFor(DidChangeConfigurationParams)
LspJson.useDefaultReaderFor(DidChangeWorkspaceFoldersParams)
LspJson.useDefaultReaderFor(WorkspaceFoldersChangeEvent)
LspJson.useDefaultReaderFor(FileEvent)
LspJson.useDefaultReaderFor(CompletionParams)
LspJson.useDefaultReaderFor(CompletionContext)
LspJson.useDefaultReaderFor(HoverParams)
LspJson.useDefaultReaderFor(ReferenceContext)
LspJson.useDefaultReaderFor(ReferenceParams)
LspJson.useDefaultReaderFor(DocumentSymbolParams)
LspJson.useDefaultReaderFor(CodeActionParams)
LspJson.useDefaultReaderFor(CodeActionContext)
LspJson.useDefaultReaderFor(FormattingOptions)
LspJson.useDefaultReaderFor(DocumentFormattingParams)
LspJson.useDefaultReaderFor(RenameParams)
LspJson.useDefaultReaderFor(PrepareRenameParams)
LspJson.useDefaultReaderFor(SignatureHelpContext)
LspJson.useDefaultReaderFor(SignatureHelpParams)
LspJson.useDefaultReaderFor(InlayHintParams)
LspJson.useDefaultReaderFor(NimLangServerStatusParams)
LspJson.useDefaultReaderFor(NimLangServerCapabilitiesParams)
LspJson.useDefaultReaderFor(SuggestParams)
LspJson.useDefaultReaderFor(RunTaskParams)
LspJson.useDefaultReaderFor(ListTestsParams)
LspJson.useDefaultReaderFor(RunTestParams)

LspJson.useDefaultWriterFor(Command)
LspJson.useDefaultWriterFor(CodeAction)
LspJson.useDefaultWriterFor(TextEdit)
LspJson.useDefaultWriterFor(WorkspaceEdit)
LspJson.useDefaultWriterFor(WorkDoneProgressBegin)
LspJson.useDefaultWriterFor(WorkDoneProgressEnd)
LspJson.useDefaultWriterFor(ProgressParams[WorkDoneProgressBegin])
LspJson.useDefaultWriterFor(ProgressParams[WorkDoneProgressEnd])
LspJson.useDefaultWriterFor(WorkDoneProgressCreateParams)
LspJson.useDefaultWriterFor(ConfigurationItem)
LspJson.useDefaultWriterFor(ConfigurationParams)
LspJson.useDefaultWriterFor(McpImplementation)
LspJson.useDefaultWriterFor(McpInitializeResult)
LspJson.useDefaultWriterFor(InitializeResult)
LspJson.useDefaultWriterFor(CompletionOptions)
LspJson.useDefaultWriterFor(SignatureHelpOptions)
LspJson.useDefaultWriterFor(ExecuteCommandOptions)
LspJson.useDefaultWriterFor(WorkspaceFoldersServerCapabilities)
LspJson.useDefaultWriterFor(WorkspaceOptions)
LspJson.useDefaultWriterFor(InlayHintOptions)
LspJson.useDefaultWriterFor(McpToolSchema)
LspJson.useDefaultWriterFor(McpTool)
LspJson.useDefaultWriterFor(McpListToolsResult)
LspJson.useDefaultWriterFor(McpContentBlock)
LspJson.useDefaultWriterFor(McpCallToolResult)
LspJson.useDefaultWriterFor(McpToolsOptions)
LspJson.useDefaultWriterFor(McpServerCapabilities)
LspJson.useDefaultWriterFor(DocumentFilter)
LspJson.useDefaultWriterFor(SaveOptions)
LspJson.useOneOfWriterFor(TextDocumentSyncOptionsSave)
LspJson.useDefaultWriterFor(TextDocumentSyncOptions)
LspJson.useDefaultWriterFor(RenameOptions)
LspJson.useOneOfWriterFor(ServerCapabilitiesTextDocumentSync)
LspJson.useOneOfWriterFor(ServerCapabilitiesRenameProvider)
LspJson.useDefaultWriterFor(WorkspaceFolder)
LspJson.useOneOfSerializationFor(RelativePatternBaseUri)
LspJson.useDefaultSerializationFor(RelativePattern)
LspJson.useOneOfSerializationFor(GlobPattern)
LspJson.useOneOfWriterFor(InlayHintTooltip)
LspJson.useDefaultWriterFor(InlayHintLabelPart)
LspJson.useOneOfWriterFor(InlayHintLabel)
LspJson.useDefaultWriterFor(InlayHintRegistrationOptions)
LspJson.useOneOfWriterFor(ServerCapabilitiesInlayHintProvider)
LspJson.useDefaultWriterFor(ServerCapabilities)
LspJson.useDefaultWriterFor(ShowMessageParams)
LspJson.useDefaultWriterFor(FileSystemWatcher)
LspJson.useDefaultWriterFor(DidChangeWatchedFilesRegistrationOptions)
LspJson.useDefaultWriterFor(Registration)
LspJson.useDefaultWriterFor(RegistrationParams)
LspJson.useDefaultWriterFor(ApplyWorkspaceEditParams)
LspJson.useDefaultReaderFor(ApplyWorkspaceEditResult)
LspJson.useDefaultWriterFor(PublishDiagnosticsParams)
LspJson.useOneOfWriterFor(CompletionItemDocumentation)
LspJson.useDefaultWriterFor(CompletionItem)
LspJson.useDefaultWriterFor(MarkedStringOption)
LspJson.useOneOfWriterFor(MarkedString)
LspJson.useOneOfWriterFor(HoverContents)
LspJson.useDefaultWriterFor(Hover)
LspJson.useDefaultWriterFor(DocumentHighlight)
LspJson.useDefaultWriterFor(SymbolInformation)
LspJson.useDefaultWriterFor(ExpandResult)
LspJson.useDefaultWriterFor(InlayHint)
LspJson.useDefaultWriterFor(PendingRequestStatus)
LspJson.useDefaultWriterFor(NimsuggestStatus)
LspJson.useDefaultWriterFor(ProjectError)
LspJson.useDefaultWriterFor(NimLangServerStatus)
LspJson.useDefaultWriterFor(SuggestResult)
LspJson.useDefaultWriterFor(NimbleTask)
LspJson.useDefaultWriterFor(RunTaskResult)
LspJson.useDefaultWriterFor(TestInfo)
LspJson.useDefaultWriterFor(TestSuiteInfo)
LspJson.useDefaultWriterFor(TestProjectInfo)
LspJson.useDefaultWriterFor(ListTestsResult)
LspJson.useDefaultWriterFor(RunTestResult)
LspJson.useDefaultWriterFor(RunTestSuiteResult)
LspJson.useDefaultWriterFor(RunTestProjectResult)
LspJson.useDefaultWriterFor(CancelTestResult)
