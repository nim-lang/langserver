import json
import options

type
  OptionalSeq*[T] = Option[seq[T]]
  OptionalNode = Option[JsonNode]

  CancelParams* = ref object of RootObj
    id*: OptionalNode

  Position* = ref object of RootObj
    line*: int  # uinteger
    character*: int  # uinteger

  Range* = ref object of RootObj
    start*: Position
    `end`*: Position

  Location* = ref object of RootObj
    uri*: string
    `range`*: Range

  Diagnostic* = ref object of RootObj
    `range`*: Range
    severity*: Option[int]
    code*: OptionalNode # int or string
    source*: Option[string]
    message*: string
    relatedInformation*: OptionalSeq[DiagnosticRelatedInformation]

  DiagnosticRelatedInformation* = ref object of RootObj
    location*: Location
    message*: string

  Command* = ref object of RootObj
    title*: string
    command*: string
    arguments*: OptionalNode

  CodeAction* = ref object of RootObj
    command*: Command
    title*: string
    kind*: string

  TextEdit* = ref object of RootObj
    `range`*: Range
    newText*: string

  TextDocumentEdit* = ref object of RootObj
    textDocument*: VersionedTextDocumentIdentifier
    edits*: OptionalSeq[TextEdit]

  WorkspaceEdit* = ref object of RootObj
    changes*: OptionalNode
    documentChanges*: OptionalSeq[TextDocumentEdit]

  TextDocumentIdentifier* = ref object of RootObj
    uri*: DocumentUri

  TextDocumentItem* = ref object of RootObj
    uri*: string
    languageId*: string
    version*: int
    text*: string

  VersionedTextDocumentIdentifier* = ref object of TextDocumentIdentifier
    version*: OptionalNode # int or float
    languageId*: Option[string]

  TextDocumentPositionParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    position*: Position

  ExpandTextDocumentPositionParams* = ref object of TextDocumentPositionParams
    level*: Option[int]

  DocumentFilter* = ref object of RootObj
    language*: Option[string]
    scheme*: Option[string]
    pattern*: Option[string]

  MarkupContent* = ref object of RootObj
    kind*: string
    value*: string

  InitializeParams_clientInfo* = ref object of RootObj
    name*: string
    version*: Option[string]

  DocumentUri = string

  # 'off' | 'messages' | 'verbose'
  TraceValue_str = string

  InitializeParams* = ref object of RootObj
    processId*: OptionalNode # int or float
    clientInfo*: Option[InitializeParams_clientInfo]
    locale*: Option[string]
    rootPath*: Option[string]
    rootUri*: DocumentUri
    initializationOptions*: OptionalNode
    capabilities*: ClientCapabilities
    trace*: Option[TraceValue_str]
    workspaceFolders*: OptionalSeq[WorkspaceFolder]

  WorkDoneProgressBegin* = ref object of RootObj
    kind*: string
    title*: string
    cancellable*: Option[bool]
    message*: Option[string]
    percentage*: Option[int]

  WorkDoneProgressReport* = ref object of RootObj
    kind*: string
    cancellable*: Option[bool]
    message*: Option[string]
    percentage*: Option[int]

  WorkDoneProgressEnd* = ref object of RootObj
    kind*: string
    message*: Option[string]

  ProgressParams* = ref object of RootObj
    token*: string # can be also int but the server will send strings
    value*: OptionalNode

  ConfigurationItem* = ref object of RootObj
    scopeUri*: Option[string]
    section*: Option[string]

  ConfigurationParams* = ref object of RootObj
    items*: seq[ConfigurationItem]

  ChangeAnnotationSupportWorkspaceEditClientCapabilities* = ref object of RootObj
    groupsOnLabel*: Option[bool]

  # 'create' | 'rename' | 'delete'
  ResourceOperationKind = string

  # 'abort' | 'transactional' | 'undo' | 'textOnlyTransactional'
  FailureHandlingKind = string

  WorkspaceEditClientCapabilities* = ref object of RootObj
    documentChanges*: Option[bool]
    resourceOperations*: OptionalSeq[ResourceOperationKind]
    failureHandling*: Option[FailureHandlingKind]
    normalizesLineEndings*: Option[bool]
    changeAnnotationSupport*: Option[ChangeAnnotationSupportWorkspaceEditClientCapabilities]

  DidChangeConfigurationClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]

  DidChangeWatchedFilesClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    relativePatternSupport*: Option[bool]

  WorkspaceSymbolClientCapabilities_symbolKind* = ref object of RootObj
    valueSet*: OptionalSeq[int]

  WorkspaceSymbolClientCapabilities_tagSupport* = ref object of RootObj
    valueSet*: seq[int]

  WorkspaceSymbolClientCapabilities_resolveSupport* = ref object of RootObj
    properties*: seq[string]

  WorkspaceSymbolClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    symbolKind*: Option[WorkspaceSymbolClientCapabilities_symbolKind]
    tagSupport*: Option[WorkspaceSymbolClientCapabilities_tagSupport]
    resolveSupport*: Option[WorkspaceSymbolClientCapabilities_ResolveSupport]

  ExecuteCommandClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]

  ClientCapabilities_workspace_fileOperations* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    didCreate*: Option[bool]
    willCreate*: Option[bool]
    didRename*: Option[bool]
    willRename*: Option[bool]
    didDelete*: Option[bool]
    willDelete*: Option[bool]

  SemanticTokensWorkspaceClientCapabilities* = ref object of RootObj
    refreshSupport*: Option[bool]

  CodeLensWorkspaceClientCapabilities* = ref object of RootObj
    refreshSupport*: Option[bool]

  InlineValueWorkspaceClientCapabilities* = ref object of RootObj
    refreshSupport*: Option[bool]

  InlayHintWorkspaceClientCapabilities* = ref object of RootObj
    refreshSupport*: Option[bool]

  DiagnosticWorkspaceClientCapabilities* = ref object of RootObj
    refreshSupport*: Option[bool]

  ClientCapabilities_workspace* = ref object of RootObj
    applyEdit*: Option[bool]
    workspaceEdit*: Option[WorkspaceEditClientCapabilities]
    didChangeConfiguration*: Option[DidChangeConfigurationClientCapabilities]
    didChangeWatchedFiles*: Option[DidChangeWatchedFilesClientCapabilities]
    symbol*: Option[WorkspaceSymbolClientCapabilities]
    executeCommand*: Option[ExecuteCommandClientCapabilities]
    workspaceFolders*: Option[bool]
    configuration*: Option[bool]
    semanticTokens*: Option[SemanticTokensWorkspaceClientCapabilities]
    codeLens*: Option[CodeLensWorkspaceClientCapabilities]
    fileOperations*: Option[ClientCapabilities_workspace_fileOperations]
    inlineValue*: Option[InlineValueWorkspaceClientCapabilities]
    inlayHint*: Option[InlayHintWorkspaceClientCapabilities]
    diagnostics*: Option[DiagnosticWorkspaceClientCapabilities]

  TextDocumentSyncClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    willSave*: Option[bool]
    willSaveWaitUntil*: Option[bool]
    didSave*: Option[bool]

  # 'plaintext' | 'markdown'
  MarkupKind_str = string

  CompletionItemTag_int = int

  CompletionClientCapabilities_completionItem_tagSupport* = ref object of RootObj
    valueSet*: seq[CompletionItemTag_int]

  CompletionClientCapabilities_completionItem_resolveSupport* = ref object of RootObj
    properties*: seq[string]

  InsertTextMode_int = int

  CompletionClientCapabilities_completionItem_insertTextModeSupport* = ref object of RootObj
    valueSet*: seq[InsertTextMode_int]

  CompletionClientCapabilities_completionItem* = ref object of RootObj
    snippetSupport*: Option[bool]
    commitCharactersSupport*: Option[bool]
    documentFormat*: OptionalSeq[MarkupKind_str]
    deprecatedSupport*: Option[bool]
    preselectSupport*: Option[bool]
    tagSupport*: Option[CompletionClientCapabilities_completionItem_tagSupport]
    insertReplaceSupport*: Option[bool]
    resolveSupport*: Option[CompletionClientCapabilities_completionItem_resolveSupport]
    insertTextModeSupport*: Option[CompletionClientCapabilities_completionItem_insertTextModeSupport]
    labelDetailsSupport*: Option[bool]

  CompletionItemKind_int = int

  CompletionClientCapabilities_completionItemKind* = ref object of RootObj
    valueSet*: OptionalSeq[CompletionItemKind_int]

  CompletionClientCapabilities_completionList* = ref object of RootObj
    itemDefaults*: OptionalSeq[string]

  CompletionClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    completionItem*: Option[CompletionClientCapabilities_completionItem]
    completionItemKind*: Option[CompletionClientCapabilities_completionItemKind]
    contextSupport*: Option[bool]
    insertTextMode*: Option[InsertTextMode_int]
    completionList*: Option[CompletionClientCapabilities_completionList]

  HoverClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    contentFormat*: OptionalSeq[MarkupKind_str]

  SignatureHelpClientCapabilities_signatureInformation_parameterInformation* = ref object of RootObj
    labelOffsetSupport*: Option[bool]

  SignatureHelpClientCapabilities_signatureInformation* = ref object of RootObj
    documentationFormat*: OptionalSeq[MarkupKind_str]
    parameterInformation*: Option[SignatureHelpClientCapabilities_signatureInformation_parameterInformation]
    activeParameterSupport*: Option[bool]

  SignatureHelpClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    signatureInformation*: Option[SignatureHelpClientCapabilities_signatureInformation]
    contextSupport*: Option[bool]

  ReferenceClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]

  DocumentHighlightClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]

  SymbolKind_int = int

  DocumentSymbolClientCapabilities_symbolKind* = ref object of RootObj
    valueSet*: OptionalSeq[SymbolKind_int]

  SymbolTag_int = int

  DocumentSymbolClientCapabilities_tagSupport* = ref object of RootObj
    valueSet*: seq[SymbolTag_int]

  DocumentSymbolClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    symbolKind*: Option[DocumentSymbolClientCapabilities_symbolKind]
    hierarchicalDocumentSymbolSupport*: Option[bool]
    tagSupport*: Option[DocumentSymbolClientCapabilities_tagSupport]
    labelSupport*: Option[bool]

  DocumentFormattingClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]

  DocumentRangeFormattingClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]

  DocumentOnTypeFormattingClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]

  DefinitionClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    linkSupport*: Option[bool]

  TypeDefinitionClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    linkSupport*: Option[bool]

  ImplementationClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    linkSupport*: Option[bool]

  CodeActionKind_str = string

  CodeActionClientCapabilities_codeActionLiteralSupport_codeActionKind* = ref object of RootObj
    valueSet*: seq[CodeActionKind_str]

  CodeActionClientCapabilities_codeActionLiteralSupport* = ref object of RootObj
    codeActionKind*: CodeActionClientCapabilities_codeActionLiteralSupport_codeActionKind

  CodeActionClientCapabilities_resolveSupport* = ref object of RootObj
    properties*: seq[string]

  CodeActionClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    codeActionLiteralSupport*: Option[CodeActionClientCapabilities_codeActionLiteralSupport]
    isPreferredSupport*: Option[bool]
    disabledSupport*: Option[bool]
    dataSupport*: Option[bool]
    resolveSupport*: Option[CodeActionClientCapabilities_resolveSupport]
    honorsChangeAnnotations*: Option[bool]

  CodeLensClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]

  DocumentLinkClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    tooltipSupport*: Option[bool]

  DocumentColorClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]

  PrepareSupportDefaultBehavior_int = int

  RenameClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    prepareSupport*: Option[bool]
    prepareSupportDefaultBehavior*: Option[PrepareSupportDefaultBehavior_int]
    honorsChangeAnnotations*: Option[bool]

  DiagnosticTag_int = int

  PublishDiagnosticsClientCapabilities_tagSupport* = ref object of RootObj
    valueSet*: seq[DiagnosticTag_int]

  PublishDiagnosticsClientCapabilities* = ref object of RootObj
    relatedInformation*: Option[bool]
    tagSupport*: Option[PublishDiagnosticsClientCapabilities_tagSupport]
    versionSupport*: Option[bool]
    codeDescriptionSupport*: Option[bool]
    dataSupport*: Option[bool]

  DeclarationClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    linkSupport*: Option[bool]

  # 'comment' | 'imports' | 'region' | ...
  FoldingRangeKind_str = string

  FoldingRangeClientCapabilities_foldingRangeKind* = ref object of RootObj
    valueSet*: OptionalSeq[FoldingRangeKind_str]

  FoldingRangeClientCapabilities_foldingRange* = ref object of RootObj
    collapsedText*: Option[bool]

  FoldingRangeClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    rangeLimit*: Option[int]  # uinteger
    lineFoldingOnly*: Option[bool]
    foldingRangeKind*: Option[FoldingRangeClientCapabilities_foldingRangeKind]
    foldingRange*: Option[FoldingRangeClientCapabilities_foldingRange]

  SelectionRangeClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]

  LinkedEditingRangeClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]

  CallHierarchyClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]

  SemanticTokensClientCapabilities_requests* = ref object of RootObj
    range*: OptionalNode  # boolean | { }
    full*: OptionalNode   # boolean | { delta?: boolean; }

  # 'relative'
  TokenFormat_str = string

  SemanticTokensClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    requests*: SemanticTokensClientCapabilities_requests
    tokenTypes*: seq[string]
    tokenModifiers*: seq[string]
    formats*: seq[TokenFormat_str]
    overlappingTokenSupport*: Option[bool]
    multilineTokenSupport*: Option[bool]
    serverCancelSupport*: Option[bool]
    augmentsSyntaxTokens*: Option[bool]

  MonikerClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]

  TypeHierarchyClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]

  InlineValueClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]

  InlayHintClientCapabilities_resolveSupport* = ref object of RootObj
    properties*: seq[string]

  InlayHintClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    resolveSupport*: Option[InlayHintClientCapabilities_resolveSupport]

  DiagnosticClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    relatedDocumentSupport*: Option[bool]

  TextDocumentClientCapabilities* = ref object of RootObj
    synchronization*: Option[TextDocumentSyncClientCapabilities]
    completion*: Option[CompletionClientCapabilities]
    hover*: Option[HoverClientCapabilities]
    signatureHelp*: Option[SignatureHelpClientCapabilities]
    declaration*: Option[DeclarationClientCapabilities]
    definition*: Option[DefinitionClientCapabilities]
    typeDefinition*: Option[TypeDefinitionClientCapabilities]
    implementation*: Option[ImplementationClientCapabilities]
    references*: Option[ReferenceClientCapabilities]
    documentHighlight*: Option[DocumentHighlightClientCapabilities]
    documentSymbol*: Option[DocumentSymbolClientCapabilities]
    codeAction*: Option[CodeActionClientCapabilities]
    codeLens*: Option[CodeLensClientCapabilities]
    documentLink*: Option[DocumentLinkClientCapabilities]
    colorProvider*: Option[DocumentColorClientCapabilities]
    formatting*: Option[DocumentFormattingClientCapabilities]
    rangeFormatting*: Option[DocumentRangeFormattingClientCapabilities]
    onTypeFormatting*: Option[DocumentOnTypeFormattingClientCapabilities]
    rename*: Option[RenameClientCapabilities]
    publishDiagnostics*: Option[PublishDiagnosticsClientCapabilities]
    foldingRange*: Option[FoldingRangeClientCapabilities]
    selectionRange*: Option[SelectionRangeClientCapabilities]
    linkedEditingRange*: Option[LinkedEditingRangeClientCapabilities]
    callHierarchy*: Option[CallHierarchyClientCapabilities]
    semanticTokens*: Option[SemanticTokensClientCapabilities]
    moniker*: Option[MonikerClientCapabilities]
    typeHierarchy*: Option[TypeHierarchyClientCapabilities]
    inlineValue*: Option[InlineValueClientCapabilities]
    inlayHint*: Option[InlayHintClientCapabilities]
    diagnostic*: Option[DiagnosticClientCapabilities]

  ShowMessageRequestClientCapabilities_messageActionItem* = ref object of RootObj
    additionalPropertiesSupport*: Option[bool]

  ShowMessageRequestClientCapabilities* = ref object of RootObj
    messageActionItem*: Option[ShowMessageRequestClientCapabilities_messageActionItem]

  ShowDocumentClientCapabilities* = ref object of RootObj
    support*: bool

  ClientCapabilities_window* = ref object of RootObj
    workDoneProgress*: Option[bool]
    showMessage*: Option[ShowMessageRequestClientCapabilities]
    showDocument*: Option[ShowDocumentClientCapabilities]

  NotebookDocumentSyncClientCapabilities* = ref object of RootObj
    dynamicRegistration*: Option[bool]
    executionSummarySupport*: Option[bool]

  NotebookDocumentClientCapabilities* = ref object of RootObj
    synchronization*: NotebookDocumentSyncClientCapabilities

  ClientCapabilities_general_staleRequestSupport* = ref object of RootObj
    cancel*: bool
    retryOnContentModified*: seq[string]

  RegularExpressionsClientCapabilities* = ref object of RootObj
    engine*: string
    version*: Option[string]

  MarkdownClientCapabilities* = ref object of RootObj
    parser*: string
    version*: Option[string]
    allowedTags*: OptionalSeq[string]

  # 'utf-8' | 'utf-16' | 'utf-32' | ...
  PositionEncodingKind_str = string

  ClientCapabilities_general* = ref object of RootObj
    staleRequestSupport*: Option[ClientCapabilities_general_staleRequestSupport]
    regularExpressions*: Option[RegularExpressionsClientCapabilities]
    markdown*: Option[MarkdownClientCapabilities]
    positionEncodings*: OptionalSeq[PositionEncodingKind_str]

  ClientCapabilities* = ref object of RootObj
    workspace*: Option[ClientCapabilities_workspace]
    textDocument*: Option[TextDocumentClientCapabilities]
    notebookDocument*: Option[NotebookDocumentClientCapabilities]
    window*: Option[ClientCapabilities_window]
    general*: Option[ClientCapabilities_general]
    experimental*: OptionalNode

  URI = string

  WorkspaceFolder* = ref object of RootObj
    uri*: URI
    name*: string

  InitializeResult_serverInfo* = ref object of RootObj
    name*: string
    version*: Option[string]

  InitializeResult* = ref object of RootObj
    capabilities*: ServerCapabilities
    #!!!serverInfo*: Option[InitializeResult_serverInfo]

  InitializeError* = ref object of RootObj
    retry*: bool

  CompletionOptions* = ref object of RootObj
    resolveProvider*: Option[bool]
    triggerCharacters*: OptionalSeq[string]

  SignatureHelpOptions* = ref object of RootObj
    triggerCharacters*: OptionalSeq[string]

  CodeLensOptions* = ref object of RootObj
    resolveProvider*: Option[bool]

  DocumentOnTypeFormattingOptions* = ref object of RootObj
    firstTriggerCharacter*: string
    moreTriggerCharacter*: OptionalSeq[string]

  DocumentLinkOptions* = ref object of RootObj
    resolveProvider*: Option[bool]

  ExecuteCommandOptions* = ref object of RootObj
   commands*: OptionalSeq[string]

  SaveOptions* = ref object of RootObj
    includeText*: Option[bool]

  ColorProviderOptions* = ref object of RootObj

  TextDocumentSyncKind_int = int

  TextDocumentSyncOptions* = ref object of RootObj
    openClose*: Option[bool]
    change*: Option[TextDocumentSyncKind_int]
    willSave*: Option[bool]
    willSaveWaitUntil*: Option[bool]
    save*: Option[SaveOptions]

  StaticRegistrationOptions* = ref object of RootObj
    id*: Option[string]

  WorkspaceFoldersServerCapabilities* = ref object of RootObj
    supported*: Option[bool]
    changeNotifications*: Option[OptionalNode] # string or bool

  # 'file' | 'folder'
  FileOperationPatternKind_str = string

  FileOperationPatternOptions* = ref object of RootObj
    ignoreCase*: Option[bool]

  FileOperationPattern* = ref object of RootObj
    glob*: string
    matches*: Option[FileOperationPatternKind_str]
    options*: Option[FileOperationPatternOptions]

  FileOperationFilter* = ref object of RootObj
    scheme*: Option[string]
    pattern: FileOperationPattern

  FileOperationRegistrationOptions* = ref object of RootObj
    filters*: seq[FileOperationFilter]

  ServerCapabilities_workspace_fileOperations* = ref object of RootObj
    didCreate*: Option[FileOperationRegistrationOptions]
    willCreate*: Option[FileOperationRegistrationOptions]
    didRename*: Option[FileOperationRegistrationOptions]
    willRename*: Option[FileOperationRegistrationOptions]
    didDelete*: Option[FileOperationRegistrationOptions]
    willDelete*: Option[FileOperationRegistrationOptions]

  ServerCapabilities_workspace* = ref object of RootObj
    workspaceFolders*: Option[WorkspaceFoldersServerCapabilities]
    #!!!!!!!fileOperations*: Option[ServerCapabilities_workspace_fileOperations]

  TextDocumentRegistrationOptions* = ref object of RootObj
    documentSelector*: OptionalSeq[DocumentFilter]

  TextDocumentAndStaticRegistrationOptions* = ref object of TextDocumentRegistrationOptions
    id*: Option[string]

  RenameOptions* = object
    # We support rename, but need to change json
    # depending on if the client supports prepare or not
    supportsPrepare*: bool

  InlayHintOptions* = object
    resolveProvider*: Option[bool]

  ServerCapabilities* = ref object of RootObj
    #!!!positionEncoding*: Option[PositionEncodingKind_str]
    textDocumentSync*: OptionalNode # TextDocumentSyncOptions or TextDocumentSyncKind_int
    #notebookDocumentSync?: NotebookDocumentSyncOptions | NotebookDocumentSyncRegistrationOptions;
    completionProvider*: CompletionOptions
    hoverProvider*: Option[bool]
    signatureHelpProvider*: SignatureHelpOptions
    declarationProvider*: Option[bool]
    definitionProvider*: Option[bool]
    typeDefinitionProvider*: Option[bool]
    implementationProvider*: OptionalNode # bool or TextDocumentAndStaticRegistrationOptions
    referencesProvider*: Option[bool]
    documentHighlightProvider*: Option[bool]
    documentSymbolProvider*: Option[bool]
    workspaceSymbolProvider*: Option[bool]
    codeActionProvider*: Option[bool]
    codeLensProvider*: CodeLensOptions
    documentLinkProvider*: Option[DocumentLinkOptions]
    # colorProvider?: boolean | DocumentColorOptions | DocumentColorRegistrationOptions;
    colorProvider*: OptionalNode # bool or ColorProviderOptions or TextDocumentAndStaticRegistrationOptions
    documentFormattingProvider*: Option[bool]
    documentRangeFormattingProvider*: Option[bool]
    documentOnTypeFormattingProvider*: DocumentOnTypeFormattingOptions
    renameProvider*: JsonNode # bool or RenameOptions
    # foldingRangeProvider?: boolean | FoldingRangeOptions | FoldingRangeRegistrationOptions;
    executeCommandProvider*: Option[ExecuteCommandOptions]
    # selectionRangeProvider?: boolean | SelectionRangeOptions | SelectionRangeRegistrationOptions;
    # linkedEditingRangeProvider?: boolean | LinkedEditingRangeOptions | LinkedEditingRangeRegistrationOptions;
    # callHierarchyProvider?: boolean | CallHierarchyOptions | CallHierarchyRegistrationOptions;
    # semanticTokensProvider?: SemanticTokensOptions | SemanticTokensRegistrationOptions;
    # monikerProvider?: boolean | MonikerOptions | MonikerRegistrationOptions;
    # typeHierarchyProvider?: boolean | TypeHierarchyOptions | TypeHierarchyRegistrationOptions;
    # inlineValueProvider?: boolean | InlineValueOptions | InlineValueRegistrationOptions;
    inlayHintProvider*: Option[InlayHintOptions]  # boolean | InlayHintOptions | InlayHintRegistrationOptions;
    # diagnosticProvider?: DiagnosticOptions | DiagnosticRegistrationOptions;
    # workspaceSymbolProvider?: boolean | WorkspaceSymbolOptions;
    workspace*: Option[ServerCapabilities_workspace]
    experimental*: OptionalNode

  InitializedParams* = ref object of RootObj
    DUMMY*: Option[nil]

  ShowMessageParams* = ref object of RootObj
    `type`*: int
    message*: string

  MessageActionItem* = ref object of RootObj
    title*: string

  ShowMessageRequestParams* = ref object of RootObj
    `type`*: int
    message*: string
    actions*: OptionalSeq[MessageActionItem]

  LogMessageParams* = ref object of RootObj
    `type`*: int
    message*: string

  Registration* = ref object of RootObj
    id*: string
    `method`*: string
    registrationOptions*: OptionalNode

  RegistrationParams* = ref object of RootObj
    registrations*: OptionalSeq[Registration]

  Unregistration* = ref object of RootObj
    id*: string
    `method`*: string

  UnregistrationParams* = ref object of RootObj
    unregistrations*: OptionalSeq[Unregistration]

  WorkspaceFoldersChangeEvent* = ref object of RootObj
    added*: OptionalSeq[WorkspaceFolder]
    removed*: OptionalSeq[WorkspaceFolder]

  DidChangeWorkspaceFoldersParams* = ref object of RootObj
    event*: WorkspaceFoldersChangeEvent

  DidChangeConfigurationParams* = ref object of RootObj
    settings*: OptionalNode

  FileEvent* = ref object of RootObj
    uri*: string
    `type`*: int

  DidChangeWatchedFilesParams* = ref object of RootObj
    changes*: OptionalSeq[FileEvent]

  DidChangeWatchedFilesRegistrationOptions* = ref object of RootObj
    watchers*: OptionalSeq[FileSystemWatcher]

  FileSystemWatcher* = ref object of RootObj
    globPattern*: string
    kind*: Option[int]

  WorkspaceSymbolParams* = ref object of RootObj
    query*: string

  ExecuteCommandParams* = ref object of RootObj
    command*: string
    arguments*: seq[JsonNode]

  ExecuteCommandRegistrationOptions* = ref object of RootObj
    commands*: OptionalSeq[string]

  ApplyWorkspaceEditParams* = ref object of RootObj
    label*: Option[string]
    edit*: WorkspaceEdit

  ApplyWorkspaceEditResponse* = ref object of RootObj
    applied*: bool

  DidOpenTextDocumentParams* = ref object of RootObj
    textDocument*: TextDocumentItem

  DidChangeTextDocumentParams* = ref object of RootObj
    textDocument*: VersionedTextDocumentIdentifier
    contentChanges*: seq[TextDocumentContentChangeEvent]

  TextDocumentContentChangeEvent* = ref object of RootObj
    range*: Option[Range]
    rangeLength*: Option[int]
    text*: string

  TextDocumentChangeRegistrationOptions* = ref object of TextDocumentRegistrationOptions
    syncKind*: int

  WillSaveTextDocumentParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    reason*: int

  DidSaveTextDocumentParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    text*: Option[string]

  TextDocumentSaveRegistrationOptions* = ref object of TextDocumentRegistrationOptions
    includeText*: Option[bool]

  DidCloseTextDocumentParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier

  PublishDiagnosticsParams* = ref object of RootObj
    uri*: string
    diagnostics*: OptionalSeq[Diagnostic]

  CompletionParams* = ref object of TextDocumentPositionParams
    context*: Option[CompletionContext]

  CompletionContext* = ref object of RootObj
    triggerKind*: int
    triggerCharacter*: Option[string]

  CompletionList* = ref object of RootObj
    isIncomplete*: bool
    `items`*: OptionalSeq[CompletionItem]

  CompletionItemLabelDetails* = ref object of RootObj
    detail*: Option[string]
    description*: Option[string]

  CompletionItem* = ref object of RootObj
    label*: string
    kind*: Option[int]
    detail*: Option[string]
    documentation*: OptionalNode #Option[string or MarkupContent]
    deprecated*: Option[bool]
    preselect*: Option[bool]
    sortText*: Option[string]
    filterText*: Option[string]
    insertText*: Option[string]
    insertTextFormat*: Option[int]
    # textEdit*: Option[TextEdit]
    # additionalTextEdits*: Option[TextEdit]
    commitCharacters*: OptionalSeq[string]
    command*: Option[Command]
    data*: OptionalNode
    labelDetails*: Option[CompletionItemLabelDetails]

  CompletionRegistrationOptions* = ref object of TextDocumentRegistrationOptions
    triggerCharacters*: OptionalSeq[string]
    resolveProvider*: Option[bool]

  MarkedStringOption* = ref object of RootObj
    language*: string
    value*: string

  Hover* = ref object of RootObj
    contents*: OptionalNode # string or MarkedStringOption or [string] or [MarkedStringOption] or MarkupContent
    range*: Option[Range]

  HoverParams* = ref object of TextDocumentPositionParams

  SignatureHelp* = ref object of RootObj
    signatures*: OptionalSeq[SignatureInformation]
    activeSignature*: Option[int]
    activeParameter*: Option[int]

  SignatureInformation* = ref object of RootObj
    label*: string
    # documentation*: Option[string]
    parameters*: seq[ParameterInformation]

  ParameterInformation* = ref object of RootObj
    label*: string
    # documentation*: Option[string]

  SignatureHelpRegistrationOptions* = ref object of TextDocumentRegistrationOptions
    triggerCharacters*: OptionalSeq[string]

  ReferenceParams* = ref object of TextDocumentPositionParams
    context*: ReferenceContext

  ReferenceContext* = ref object of RootObj
    includeDeclaration*: bool

  DocumentHighlight* = ref object of RootObj
    `range`*: Range
    kind*: Option[int]

  DocumentSymbolParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier

  SymbolInformation* = ref object of RootObj
    name*: string
    kind*: int
    deprecated*: Option[bool]
    location*: Location
    containerName*: Option[string]

  CodeActionParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    `range`*: Range
    context*: CodeActionContext

  CodeActionContext* = ref object of RootObj
    diagnostics*: OptionalSeq[Diagnostic]

  CodeLensParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier

  CodeLens* = ref object of RootObj
    `range`*: Range
    command*: Option[Command]
    data*: OptionalNode

  CodeLensRegistrationOptions* = ref object of TextDocumentRegistrationOptions
    resolveProvider*: Option[bool]

  DocumentLinkParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier

  DocumentLink* = ref object of RootObj
    `range`*: Range
    target*: Option[string]
    data*: OptionalNode

  DocumentLinkRegistrationOptions* = ref object of TextDocumentRegistrationOptions
    resolveProvider*: Option[bool]

  DocumentColorParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier

  ColorInformation* = ref object of RootObj
    `range`*: Range
    color*: Color

  Color* = ref object of RootObj
    red*: int
    green*: int
    blue*: int
    alpha*: int

  ColorPresentationParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    color*: Color
    `range`*: Range

  ColorPresentation* = ref object of RootObj
    label*: string
    textEdit*: Option[TextEdit]
    additionalTextEdits*: OptionalSeq[TextEdit]

  DocumentFormattingParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    options*: OptionalNode

  DocumentRangeFormattingParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    `range`*: Range
    options*: OptionalNode

  DocumentOnTypeFormattingParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    position*: Position
    ch*: string
    options*: OptionalNode

  DocumentOnTypeFormattingRegistrationOptions* = ref object of TextDocumentRegistrationOptions
    firstTriggerCharacter*: string
    moreTriggerCharacter*: OptionalSeq[string]

  RenameParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    position*: Position
    newName*: string

  PrepareRenameParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    position*: Position

  PrepareRenameResponse* = ref object of RootObj
    defaultBehaviour*: bool

  SignatureHelpContext* = ref object of RootObj
    triggerKind*: int
    triggerCharacter*: Option[string]
    isRetrigger*: bool
    activeSignatureHelp*: Option[SignatureHelp]

  SignatureHelpParams* = ref object of TextDocumentPositionParams
    context*: Option[SignatureHelpContext]

  ExpandResult* = ref object of RootObj
    range*: Range
    content*: string

  InlayHintParams* = ref object of RootObj  # TODO: extends WorkDoneProgressParams
    textDocument*: TextDocumentIdentifier
    range*: Range

  InlayHintKind_int* = int

  InlayHint* = ref object of RootObj
    position*: Position
    label*: string  # string | InlayHintLabelPart[]
    kind*: Option[InlayHintKind_int]
    textEdits*: OptionalSeq[TextEdit]
    tooltip*: Option[string]  # string | MarkupContent
    paddingLeft*: Option[bool]
    paddingRight*: Option[bool]
    #data*: OptionalNode
