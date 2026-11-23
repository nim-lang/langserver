import
  std/[hashes, options, paths, tables, uri],
  chronicles,
  json_rpc/router,
  json_serialization,
  json_serialization/std/[options as jsoptions, tables as jstables],
  ./[oneof, extends]

export
  json_serialization, jsoptions, jstables, paths, uri, RequestId, RequestIdKind, Null

type
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

# https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#baseTypes
type uinteger* = distinct int

const uintegerHigh* = uinteger(int32.high)

extendTypes:
  type
    OptionalSeq*[T] = Option[seq[T]]
    LspAny* = JsonString

    CancelParams* = object
      id*: RequestId

    Position* = object
      line*: uinteger
      character*: uinteger

    Range* = object
      start*: Position
      `end`*: Position

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

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#diagnostic
    Diagnostic* = object
      `range`*: Range
      severity*: Option[int]
      code*: Option[DiagnosticCode]
      source*: Option[string]
      message*: string
      relatedInformation*: OptionalSeq[DiagnosticRelatedInformation]

    DiagnosticRelatedInformation* = object
      location*: Location
      message*: string

    Command* = object
      title*: string
      command*: string
      arguments*: OptionalSeq[LspAny]

    CodeAction* = object
      command*: Option[Command]
      title*: string
      kind*: string

    TextEdit* = object
      `range`*: Range
      newText*: string

    TextDocumentEdit* = object
      textDocument*: VersionedTextDocumentIdentifier
      edits*: OptionalSeq[TextEdit]

    WorkspaceEdit* = object
      changes*: Option[Table[DocumentUri, seq[TextEdit]]]
      documentChanges*: OptionalSeq[TextDocumentEdit]

    TextDocumentIdentifier* = object
      uri*: DocumentUri

    TextDocumentItem* = object
      uri*: DocumentUri
      languageId*: string
      version*: int
      text*: string

    VersionedTextDocumentIdentifier* {.extends: [TextDocumentIdentifier].} = object
      version*: Option[int]
      languageId*: Option[string]

    TextDocumentPositionParams* = object
      textDocument*: TextDocumentIdentifier
      position*: Position

    ExpandTextDocumentPositionParams* {.extends: [TextDocumentPositionParams].} = object
      level*: Option[int]

    DocumentFilter* = object
      language*: Option[string]
      scheme*: Option[string]
      pattern*: Option[string]

    MarkupContent* = object
      kind*: string
      value*: string

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#notificationparams
    McpNotificationParams* = object
      meta* {.serializedFieldName: "_meta".}: Option[OrderedTable[string, JsonString]]

    McpListToolsParams* = object

    McpCallToolParams* = object
      name*: string
      arguments*: Option[JsonString]

    McpInitializeParams_clientInfo_Icon_theme* = enum
      light = "light"
      dark = "dark"

    McpInitializeParams_clientInfo_Icon* = object
      src*: string
      mimeType*: Option[string]
      sizes*: OptionalSeq[string]
      theme*: Option[McpInitializeParams_clientInfo_Icon_theme]

    McpInitializeParams_clientInfo* = object
      icons*: OptionalSeq[McpInitializeParams_clientInfo_Icon]
      name*: string
      title*: Option[string]
      version*: string
      description*: Option[string]
      websiteUrl*: Option[string]

    LspInitializeParams_clientInfo* = object
      name*: string
      version*: Option[string]

    # 'off' | 'messages' | 'verbose'
    TraceValue_str = string

    McpInitializeParams* = object
      protocolVersion*: string
      capabilities*: McpClientCapabilities
      clientInfo*: McpInitializeParams_clientInfo

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initializeParams
    BaseInitializeParams* {.extends: [WorkDoneProgressParams].} = object
      processId*: Option[int]
      clientInfo*: Option[LspInitializeParams_clientInfo]
      locale*: Option[string]
      rootPath*: Option[string]
      rootUri*: Option[DocumentUri]
      capabilities*: LspClientCapabilities
      initializationOptions*: Option[LspAny]
      trace*: Option[TraceValue_str]

    WorkspaceFoldersInitializeParams* = object
      workspaceFolders*: OptionalSeq[WorkspaceFolder]

    LspInitializeParams* {.
      extends: [BaseInitializeParams, WorkspaceFoldersInitializeParams]
    .} = object

    SetTraceParams* = object
      value*: TraceValue_str

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workDoneProgressBegin
    ProgressTokenKind* = enum
      ptNum
      ptStr

    ProgressToken* = object
      case kind*: ProgressTokenKind
      of ptNum:
        num*: int
      of ptStr:
        str*: string

    WorkDoneProgressParams* = object
      workDoneToken*: Option[ProgressToken]

    PartialResultParams* = object
      partialResultToken*: Option[ProgressToken]

    WorkDoneProgressOptions* = object
      workDoneProgress*: Option[bool]

    WorkDoneProgressBegin* = object
      kind*: string
      title*: string
      cancellable*: Option[bool]
      message*: Option[string]
      percentage*: Option[uinteger]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workDoneProgressReport
    WorkDoneProgressReport* = object
      kind*: string
      cancellable*: Option[bool]
      message*: Option[string]
      percentage*: Option[uinteger]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workDoneProgressEnd
    WorkDoneProgressEnd* = object
      kind*: string
      message*: Option[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#progress
    ProgressParams*[T] = object
      token*: string # can be also int but the server will send strings
      value*: T

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_workDoneProgress_create
    WorkDoneProgressCreateParams* = object
      token*: string # can be also int but the server will send strings

    ConfigurationItem* = object
      scopeUri*: Option[string]
      section*: Option[string]

    ConfigurationParams* = object
      items*: seq[ConfigurationItem]

    ChangeAnnotationSupportWorkspaceEditClientCapabilities* = object
      groupsOnLabel*: Option[bool]

    # 'create' | 'rename' | 'delete'
    ResourceOperationKind = string

    # 'abort' | 'transactional' | 'undo' | 'textOnlyTransactional'
    FailureHandlingKind = string

    WorkspaceEditClientCapabilities* = object
      documentChanges*: Option[bool]
      resourceOperations*: OptionalSeq[ResourceOperationKind]
      failureHandling*: Option[FailureHandlingKind]
      normalizesLineEndings*: Option[bool]
      changeAnnotationSupport*:
        Option[ChangeAnnotationSupportWorkspaceEditClientCapabilities]

    DidChangeConfigurationClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    DidChangeWatchedFilesClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      relativePatternSupport*: Option[bool]

    WorkspaceSymbolClientCapabilities_symbolKind* = object
      valueSet*: OptionalSeq[int]

    WorkspaceSymbolClientCapabilities_tagSupport* = object
      valueSet*: seq[int]

    WorkspaceSymbolClientCapabilities_resolveSupport* = object
      properties*: seq[string]

    WorkspaceSymbolClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      symbolKind*: Option[WorkspaceSymbolClientCapabilities_symbolKind]
      tagSupport*: Option[WorkspaceSymbolClientCapabilities_tagSupport]
      resolveSupport*: Option[WorkspaceSymbolClientCapabilities_resolveSupport]

    ExecuteCommandClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    ClientCapabilities_workspace_fileOperations* = object
      dynamicRegistration*: Option[bool]
      didCreate*: Option[bool]
      willCreate*: Option[bool]
      didRename*: Option[bool]
      willRename*: Option[bool]
      didDelete*: Option[bool]
      willDelete*: Option[bool]

    SemanticTokensWorkspaceClientCapabilities* = object
      refreshSupport*: Option[bool]

    CodeLensWorkspaceClientCapabilities* = object
      refreshSupport*: Option[bool]

    InlineValueWorkspaceClientCapabilities* = object
      refreshSupport*: Option[bool]

    InlayHintWorkspaceClientCapabilities* = object
      refreshSupport*: Option[bool]

    DiagnosticWorkspaceClientCapabilities* = object
      refreshSupport*: Option[bool]

    ClientCapabilities_workspace* = object
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

    TextDocumentSyncClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      willSave*: Option[bool]
      willSaveWaitUntil*: Option[bool]
      didSave*: Option[bool]

    # 'plaintext' | 'markdown'
    MarkupKind_str = string

    CompletionItemTag_int = int

    CompletionClientCapabilities_completionItem_tagSupport* = object
      valueSet*: seq[CompletionItemTag_int]

    CompletionClientCapabilities_completionItem_resolveSupport* = object
      properties*: seq[string]

    InsertTextMode_int = int

    CompletionClientCapabilities_completionItem_insertTextModeSupport* = object
      valueSet*: seq[InsertTextMode_int]

    CompletionClientCapabilities_completionItem* = object
      snippetSupport*: Option[bool]
      commitCharactersSupport*: Option[bool]
      documentFormat*: OptionalSeq[MarkupKind_str]
      deprecatedSupport*: Option[bool]
      preselectSupport*: Option[bool]
      tagSupport*: Option[CompletionClientCapabilities_completionItem_tagSupport]
      insertReplaceSupport*: Option[bool]
      resolveSupport*:
        Option[CompletionClientCapabilities_completionItem_resolveSupport]
      insertTextModeSupport*:
        Option[CompletionClientCapabilities_completionItem_insertTextModeSupport]
      labelDetailsSupport*: Option[bool]

    CompletionItemKind_int = int

    CompletionClientCapabilities_completionItemKind* = object
      valueSet*: OptionalSeq[CompletionItemKind_int]

    CompletionClientCapabilities_completionList* = object
      itemDefaults*: OptionalSeq[string]

    CompletionClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      completionItem*: Option[CompletionClientCapabilities_completionItem]
      completionItemKind*: Option[CompletionClientCapabilities_completionItemKind]
      contextSupport*: Option[bool]
      insertTextMode*: Option[InsertTextMode_int]
      completionList*: Option[CompletionClientCapabilities_completionList]

    HoverClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      contentFormat*: OptionalSeq[MarkupKind_str]

    SignatureHelpClientCapabilities_signatureInformation_parameterInformation* = object
      labelOffsetSupport*: Option[bool]

    SignatureHelpClientCapabilities_signatureInformation* = object
      documentationFormat*: OptionalSeq[MarkupKind_str]
      parameterInformation*: Option[
        SignatureHelpClientCapabilities_signatureInformation_parameterInformation
      ]
      activeParameterSupport*: Option[bool]

    SignatureHelpClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      signatureInformation*:
        Option[SignatureHelpClientCapabilities_signatureInformation]
      contextSupport*: Option[bool]

    ReferenceClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    DocumentHighlightClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    SymbolKind_int = int

    DocumentSymbolClientCapabilities_symbolKind* = object
      valueSet*: OptionalSeq[SymbolKind_int]

    SymbolTag_int = int

    DocumentSymbolClientCapabilities_tagSupport* = object
      valueSet*: seq[SymbolTag_int]

    DocumentSymbolClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      symbolKind*: Option[DocumentSymbolClientCapabilities_symbolKind]
      hierarchicalDocumentSymbolSupport*: Option[bool]
      tagSupport*: Option[DocumentSymbolClientCapabilities_tagSupport]
      labelSupport*: Option[bool]

    DocumentFormattingClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    DocumentRangeFormattingClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    DocumentOnTypeFormattingClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    DefinitionClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      linkSupport*: Option[bool]

    TypeDefinitionClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      linkSupport*: Option[bool]

    ImplementationClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      linkSupport*: Option[bool]

    CodeActionKind_str = string

    CodeActionClientCapabilities_codeActionLiteralSupport_codeActionKind* = object
      valueSet*: seq[CodeActionKind_str]

    CodeActionClientCapabilities_codeActionLiteralSupport* = object
      codeActionKind*:
        CodeActionClientCapabilities_codeActionLiteralSupport_codeActionKind

    CodeActionClientCapabilities_resolveSupport* = object
      properties*: seq[string]

    CodeActionClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      codeActionLiteralSupport*:
        Option[CodeActionClientCapabilities_codeActionLiteralSupport]
      isPreferredSupport*: Option[bool]
      disabledSupport*: Option[bool]
      dataSupport*: Option[bool]
      resolveSupport*: Option[CodeActionClientCapabilities_resolveSupport]
      honorsChangeAnnotations*: Option[bool]

    CodeLensClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    DocumentLinkClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      tooltipSupport*: Option[bool]

    DocumentColorClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    PrepareSupportDefaultBehavior_int = int

    RenameClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      prepareSupport*: Option[bool]
      prepareSupportDefaultBehavior*: Option[PrepareSupportDefaultBehavior_int]
      honorsChangeAnnotations*: Option[bool]

    DiagnosticTag_int = int

    PublishDiagnosticsClientCapabilities_tagSupport* = object
      valueSet*: seq[DiagnosticTag_int]

    DiagnosticsCapabilities* = object
      relatedInformation*: Option[bool]
      tagSupport*: Option[PublishDiagnosticsClientCapabilities_tagSupport]
      codeDescriptionSupport*: Option[bool]
      dataSupport*: Option[bool]

    PublishDiagnosticsClientCapabilities* {.extends: [DiagnosticsCapabilities].} = object
      versionSupport*: Option[bool]

    DeclarationClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      linkSupport*: Option[bool]

    # 'comment' | 'imports' | 'region' | ...
    FoldingRangeKind_str = string

    FoldingRangeClientCapabilities_foldingRangeKind* = object
      valueSet*: OptionalSeq[FoldingRangeKind_str]

    FoldingRangeClientCapabilities_foldingRange* = object
      collapsedText*: Option[bool]

    FoldingRangeClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      rangeLimit*: Option[uinteger]
      lineFoldingOnly*: Option[bool]
      foldingRangeKind*: Option[FoldingRangeClientCapabilities_foldingRangeKind]
      foldingRange*: Option[FoldingRangeClientCapabilities_foldingRange]

    SelectionRangeClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    LinkedEditingRangeClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    CallHierarchyClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    EmptyObject* = object

    ClientSemanticTokensRequestRangeKind* = enum
      cstrBool
      cstrEmpty

    ClientSemanticTokensRequestRange* = object
      case kind*: ClientSemanticTokensRequestRangeKind
      of cstrBool:
        boolean*: bool
      of cstrEmpty:
        empty*: EmptyObject

    ClientSemanticTokensRequestFullKind* = enum
      cstfBool
      cstfDelta

    ClientSemanticTokensRequestFull* = object
      case kind*: ClientSemanticTokensRequestFullKind
      of cstfBool:
        boolean*: bool
      of cstfDelta:
        delta*: ClientSemanticTokensRequestFullDelta

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientSemanticTokensRequestOptions
    ClientSemanticTokensRequestOptions* = object
      range*: Option[ClientSemanticTokensRequestRange]
      full*: Option[ClientSemanticTokensRequestFull]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientSemanticTokensRequestFullDelta
    ClientSemanticTokensRequestFullDelta* = object
      delta*: Option[bool]

    # 'relative'
    TokenFormat_str = string

    SemanticTokensClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      requests*: ClientSemanticTokensRequestOptions
      tokenTypes*: seq[string]
      tokenModifiers*: seq[string]
      formats*: seq[TokenFormat_str]
      overlappingTokenSupport*: Option[bool]
      multilineTokenSupport*: Option[bool]
      serverCancelSupport*: Option[bool]
      augmentsSyntaxTokens*: Option[bool]

    MonikerClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    TypeHierarchyClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    InlineValueClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    InlayHintClientCapabilities_resolveSupport* = object
      properties*: seq[string]

    InlayHintClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      resolveSupport*: Option[InlayHintClientCapabilities_resolveSupport]

    DiagnosticClientCapabilities* {.extends: [DiagnosticsCapabilities].} = object
      dynamicRegistration*: Option[bool]
      relatedDocumentSupport*: Option[bool]

    TextDocumentClientCapabilities* = object
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

    ShowMessageRequestClientCapabilities_messageActionItem* = object
      additionalPropertiesSupport*: Option[bool]

    ShowMessageRequestClientCapabilities* = object
      messageActionItem*: Option[ShowMessageRequestClientCapabilities_messageActionItem]

    ShowDocumentClientCapabilities* = object
      support*: bool

    ClientCapabilities_window* = object
      workDoneProgress*: Option[bool]
      showMessage*: Option[ShowMessageRequestClientCapabilities]
      showDocument*: Option[ShowDocumentClientCapabilities]

    NotebookDocumentSyncClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      executionSummarySupport*: Option[bool]

    NotebookDocumentClientCapabilities* = object
      synchronization*: NotebookDocumentSyncClientCapabilities

    ClientCapabilities_general_staleRequestSupport* = object
      cancel*: bool
      retryOnContentModified*: seq[string]

    RegularExpressionsClientCapabilities* = object
      engine*: string
      version*: Option[string]

    MarkdownClientCapabilities* = object
      parser*: string
      version*: Option[string]
      allowedTags*: OptionalSeq[string]

    # 'utf-8' | 'utf-16' | 'utf-32' | ...
    PositionEncodingKind_str = string

    ClientCapabilities_general* = object
      staleRequestSupport*: Option[ClientCapabilities_general_staleRequestSupport]
      regularExpressions*: Option[RegularExpressionsClientCapabilities]
      markdown*: Option[MarkdownClientCapabilities]
      positionEncodings*: OptionalSeq[PositionEncodingKind_str]

    McpClientCapabilities* = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientCapabilities
    LspClientCapabilities* = object
      workspace*: Option[ClientCapabilities_workspace]
      textDocument*: Option[TextDocumentClientCapabilities]
      notebookDocument*: Option[NotebookDocumentClientCapabilities]
      window*: Option[ClientCapabilities_window]
      general*: Option[ClientCapabilities_general]
      experimental*: Option[LspAny]

    WorkspaceFolder* = object
      uri*: LspUri
      name*: string

    McpInitializeParams_serverInfo* = object
      name*: string
      version*: string

    McpInitializeResult* = object
      protocolVersion*: string
      capabilities*: McpServerCapabilities
      serverInfo*: McpInitializeParams_serverInfo

    LspInitializeResult* = object
      capabilities*: LspServerCapabilities
      #!!!serverInfo*: Option[InitializeResult_serverInfo]

    InitializeError* = object
      retry*: bool

    CompletionOptions* {.extends: [WorkDoneProgressOptions].} = object
      resolveProvider*: Option[bool]
      triggerCharacters*: OptionalSeq[string]

    SignatureHelpOptions* {.extends: [WorkDoneProgressOptions].} = object
      triggerCharacters*: OptionalSeq[string]

    CodeLensOptions* {.extends: [WorkDoneProgressOptions].} = object
      resolveProvider*: Option[bool]

    DocumentOnTypeFormattingOptions* = object
      firstTriggerCharacter*: string
      moreTriggerCharacter*: OptionalSeq[string]

    DocumentLinkOptions* {.extends: [WorkDoneProgressOptions].} = object
      resolveProvider*: Option[bool]

    ExecuteCommandOptions* {.extends: [WorkDoneProgressOptions].} = object
      commands*: OptionalSeq[string]

    SaveOptions* = object
      includeText*: Option[bool]

    TextDocumentSyncKind_int = int

    TextDocumentSyncOptions* = object
      openClose*: Option[bool]
      change*: Option[TextDocumentSyncKind_int]
      willSave*: Option[bool]
      willSaveWaitUntil*: Option[bool]
      save*: Option[SaveOptions]

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

    WorkspaceFoldersServerCapabilities* = object
      supported*: Option[bool]
      changeNotifications*: Option[WorkspaceFoldersChangeNotifications]

    # 'file' | 'folder'
    FileOperationPatternKind_str = string

    FileOperationPatternOptions* = object
      ignoreCase*: Option[bool]

    FileOperationPattern* = object
      glob*: string
      matches*: Option[FileOperationPatternKind_str]
      options*: Option[FileOperationPatternOptions]

    FileOperationFilter* = object
      scheme*: Option[string]
      pattern: FileOperationPattern

    FileOperationRegistrationOptions* = object
      filters*: seq[FileOperationFilter]

    ServerCapabilities_workspace_fileOperations* = object
      didCreate*: Option[FileOperationRegistrationOptions]
      willCreate*: Option[FileOperationRegistrationOptions]
      didRename*: Option[FileOperationRegistrationOptions]
      willRename*: Option[FileOperationRegistrationOptions]
      didDelete*: Option[FileOperationRegistrationOptions]
      willDelete*: Option[FileOperationRegistrationOptions]

    ServerCapabilities_workspace* = object
      workspaceFolders*: Option[WorkspaceFoldersServerCapabilities]
      #!!!!!!!fileOperations*: Option[ServerCapabilities_workspace_fileOperations]

    DocumentSelector* = seq[DocumentFilter]

    TextDocumentRegistrationOptionsDocumentSelectorKind* = enum
      tdrdsNull
      tdrdsSelector

    TextDocumentRegistrationOptionsDocumentSelector* = object
      case kind*: TextDocumentRegistrationOptionsDocumentSelectorKind
      of tdrdsNull:
        null*: Null
      of tdrdsSelector:
        selector*: DocumentSelector

    TextDocumentRegistrationOptions* = object
      documentSelector*: TextDocumentRegistrationOptionsDocumentSelector

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#renameOptions
    RenameOptions* {.extends: [WorkDoneProgressOptions].} = object
      prepareProvider*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#implementationOptions
    ImplementationOptions* {.extends: [WorkDoneProgressOptions].} = object

    ImplementationRegistrationOptions* {.
      extends: [
        TextDocumentRegistrationOptions, ImplementationOptions,
        StaticRegistrationOptions,
      ]
    .} = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentColorOptions
    DocumentColorOptions* {.extends: [WorkDoneProgressOptions].} = object

    DocumentColorRegistrationOptions* {.
      extends: [
        TextDocumentRegistrationOptions, DocumentColorOptions, StaticRegistrationOptions
      ]
    .} = object

    ServerCapabilitiesTextDocumentSyncKind* = enum
      stdsOptions
      stdsKind

    ServerCapabilitiesTextDocumentSync* = object
      case kind*: ServerCapabilitiesTextDocumentSyncKind
      of stdsOptions:
        options*: TextDocumentSyncOptions
      of stdsKind:
        syncKind*: TextDocumentSyncKind_int

    ServerCapabilitiesImplementationProviderKind* = enum
      sipBool
      sipOptions
      sipRegistration

    ServerCapabilitiesImplementationProvider* = object
      case kind*: ServerCapabilitiesImplementationProviderKind
      of sipBool:
        boolean*: bool
      of sipOptions:
        options*: ImplementationOptions
      of sipRegistration:
        registration*: ImplementationRegistrationOptions

    ServerCapabilitiesColorProviderKind* = enum
      scpBool
      scpOptions
      scpRegistration

    ServerCapabilitiesColorProvider* = object
      case kind*: ServerCapabilitiesColorProviderKind
      of scpBool:
        boolean*: bool
      of scpOptions:
        options*: DocumentColorOptions
      of scpRegistration:
        registration*: DocumentColorRegistrationOptions

    ServerCapabilitiesRenameProviderKind* = enum
      srpBool
      srpOptions

    ServerCapabilitiesRenameProvider* = object
      case kind*: ServerCapabilitiesRenameProviderKind
      of srpBool:
        boolean*: bool
      of srpOptions:
        options*: RenameOptions

    InlayHintOptions* {.extends: [WorkDoneProgressOptions].} = object
      resolveProvider*: Option[bool]

    McpToolSchema* = object
      schema* {.serializedFieldName: "$schema".}: Option[string]
      `type`*: string
      properties*: Option[OrderedTable[string, JsonString]]
      required*: Option[seq[string]]

    # https://modelcontextprotocol.io/specification/2026-07-28/schema#tool
    McpTool* = object
      name*: string
      title*: string
      description*: string
      inputSchema*: McpToolSchema
      outputSchema*: Option[McpToolSchema]

    McpListToolsResult* = object
      tools*: seq[McpTool]

    McpContentBlockType* = enum
      TextContent = "text"

    McpContentBlock* = object
      case `type`*: McpContentBlockType
      of TextContent:
        text*: string

    # https://modelcontextprotocol.io/specification/2026-07-28/schema#calltoolresult
    McpCallToolResult* = object
      content*: seq[McpContentBlock]
      structuredContent*: Option[JsonString]
      isError*: bool

    McpToolsOptions* = object

    McpServerCapabilities* = object
      tools*: McpToolsOptions

    LspServerCapabilities* = object
      #!!!positionEncoding*: Option[PositionEncodingKind_str]
      textDocumentSync*: Option[ServerCapabilitiesTextDocumentSync]
      #notebookDocumentSync?: NotebookDocumentSyncOptions | NotebookDocumentSyncRegistrationOptions;
      completionProvider*: Option[CompletionOptions]
      hoverProvider*: Option[bool]
      signatureHelpProvider*: Option[SignatureHelpOptions]
      declarationProvider*: Option[bool]
      definitionProvider*: Option[bool]
      typeDefinitionProvider*: Option[bool]
      implementationProvider*: Option[ServerCapabilitiesImplementationProvider]
      referencesProvider*: Option[bool]
      documentHighlightProvider*: Option[bool]
      documentSymbolProvider*: Option[bool]
      workspaceSymbolProvider*: Option[bool]
      codeActionProvider*: Option[bool]
      codeLensProvider*: Option[CodeLensOptions]
      documentLinkProvider*: Option[DocumentLinkOptions]
      colorProvider*: Option[ServerCapabilitiesColorProvider]
      documentFormattingProvider*: Option[bool]
      documentRangeFormattingProvider*: Option[bool]
      documentOnTypeFormattingProvider*: Option[DocumentOnTypeFormattingOptions]
      renameProvider*: Option[ServerCapabilitiesRenameProvider]
      # foldingRangeProvider?: boolean | FoldingRangeOptions | FoldingRangeRegistrationOptions;
      executeCommandProvider*: Option[ExecuteCommandOptions]
      # selectionRangeProvider?: boolean | SelectionRangeOptions | SelectionRangeRegistrationOptions;
      # linkedEditingRangeProvider?: boolean | LinkedEditingRangeOptions | LinkedEditingRangeRegistrationOptions;
      # callHierarchyProvider?: boolean | CallHierarchyOptions | CallHierarchyRegistrationOptions;
      # semanticTokensProvider?: SemanticTokensOptions | SemanticTokensRegistrationOptions;
      # monikerProvider?: boolean | MonikerOptions | MonikerRegistrationOptions;
      # typeHierarchyProvider?: boolean | TypeHierarchyOptions | TypeHierarchyRegistrationOptions;
      # inlineValueProvider?: boolean | InlineValueOptions | InlineValueRegistrationOptions;
      inlayHintProvider*: Option[InlayHintOptions]
        # boolean | InlayHintOptions | InlayHintRegistrationOptions;
      # diagnosticProvider?: DiagnosticOptions | DiagnosticRegistrationOptions;
      # workspaceSymbolProvider?: boolean | WorkspaceSymbolOptions;
      workspace*: Option[ServerCapabilities_workspace]
      experimental*: Option[LspAny]

    InitializedParams* = object

    ShowMessageParams* = object
      `type`*: int
      message*: string

    MessageActionItem* = object
      title*: string

    ShowMessageRequestParams* = object
      `type`*: int
      message*: string
      actions*: OptionalSeq[MessageActionItem]

    LogMessageParams* = object
      `type`*: int
      message*: string

    Registration* = object
      id*: string
      `method`*: string
      registerOptions*: Option[LspAny]

    RegistrationParams* = object
      registrations*: OptionalSeq[Registration]

    Unregistration* = object
      id*: string
      `method`*: string

    UnregistrationParams* = object
      unregistrations*: OptionalSeq[Unregistration]

    WorkspaceFoldersChangeEvent* = object
      added*: OptionalSeq[WorkspaceFolder]
      removed*: OptionalSeq[WorkspaceFolder]

    DidChangeWorkspaceFoldersParams* = object
      event*: WorkspaceFoldersChangeEvent

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_didChangeConfiguration
    # XXX remove Option when skipNullFields = false
    DidChangeConfigurationParams* = object
      settings*: Option[LspAny]

    FileEvent* = object
      uri*: DocumentUri
      `type`*: int

    DidChangeWatchedFilesParams* = object
      changes*: OptionalSeq[FileEvent]

    DidChangeWatchedFilesRegistrationOptions* = object
      watchers*: OptionalSeq[FileSystemWatcher]

    FileSystemWatcher* = object
      globPattern*: string
      kind*: Option[int]

    WorkspaceSymbolParams* {.extends: [WorkDoneProgressParams, PartialResultParams].} = object
      query*: string

    ExecuteCommandParams* {.extends: [WorkDoneProgressParams].} = object
      command*: string
      arguments*: OptionalSeq[LspAny]

    ExecuteCommandRegistrationOptions* {.extends: [ExecuteCommandOptions].} = object

    ApplyWorkspaceEditParams* = object
      label*: Option[string]
      edit*: WorkspaceEdit

    ApplyWorkspaceEditResponse* = object
      applied*: bool

    DidOpenTextDocumentParams* = object
      textDocument*: TextDocumentItem

    DidChangeTextDocumentParams* = object
      textDocument*: VersionedTextDocumentIdentifier
      contentChanges*: seq[TextDocumentContentChangeEvent]

    TextDocumentContentChangeEvent* = object
      range*: Option[Range]
      rangeLength*: Option[int]
      text*: string

    TextDocumentChangeRegistrationOptions* {.
      extends: [TextDocumentRegistrationOptions]
    .} = object
      syncKind*: int

    WillSaveTextDocumentParams* = object
      textDocument*: TextDocumentIdentifier
      reason*: int

    DidSaveTextDocumentParams* = object
      textDocument*: TextDocumentIdentifier
      text*: Option[string]

    TextDocumentSaveRegistrationOptions* {.
      extends: [TextDocumentRegistrationOptions, SaveOptions]
    .} = object

    DidCloseTextDocumentParams* = object
      textDocument*: TextDocumentIdentifier

    PublishDiagnosticsParams* = object
      uri*: DocumentUri
      diagnostics*: OptionalSeq[Diagnostic]

    CompletionParams* {.
      extends: [TextDocumentPositionParams, WorkDoneProgressParams, PartialResultParams]
    .} = object
      context*: Option[CompletionContext]

    CompletionContext* = object
      triggerKind*: int
      triggerCharacter*: Option[string]

    CompletionList* = object
      isIncomplete*: bool
      `items`*: OptionalSeq[CompletionItem]

    CompletionItemLabelDetails* = object
      detail*: Option[string]
      description*: Option[string]

    CompletionItemDocumentationKind* = enum
      cidStr
      cidMarkup

    CompletionItemDocumentation* = object
      case kind*: CompletionItemDocumentationKind
      of cidStr:
        str*: string
      of cidMarkup:
        markup*: MarkupContent

    CompletionItem* = object
      label*: string
      kind*: Option[int]
      detail*: Option[string]
      documentation*: Option[CompletionItemDocumentation]
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
      data*: Option[LspAny]
      labelDetails*: Option[CompletionItemLabelDetails]

    CompletionRegistrationOptions* {.
      extends: [TextDocumentRegistrationOptions, CompletionOptions]
    .} = object

    MarkedStringOption* = object
      language*: string
      value*: string

    MarkedStringKind* = enum
      msStr
      msOption

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

    HoverParams* {.extends: [TextDocumentPositionParams, WorkDoneProgressParams].} = object

    SignatureHelp* = object
      signatures*: OptionalSeq[SignatureInformation]
      activeSignature*: Option[int]
      activeParameter*: Option[int]

    SignatureInformation* = object
      label*: string
      # documentation*: Option[string]
      parameters*: seq[ParameterInformation]

    ParameterInformation* = object
      label*: string # documentation*: Option[string]

    SignatureHelpRegistrationOptions* {.
      extends: [TextDocumentRegistrationOptions, SignatureHelpOptions]
    .} = object

    ReferenceParams* {.
      extends: [TextDocumentPositionParams, WorkDoneProgressParams, PartialResultParams]
    .} = object
      context*: ReferenceContext

    ReferenceContext* = object
      includeDeclaration*: bool

    DocumentHighlight* = object
      `range`*: Range
      kind*: Option[int]

    DocumentSymbolParams* {.extends: [WorkDoneProgressParams, PartialResultParams].} = object
      textDocument*: TextDocumentIdentifier

    BaseSymbolInformation* = object
      name*: string
      kind*: int
      tags*: OptionalSeq[SymbolTag_int]
      containerName*: Option[string]

    SymbolInformation* {.extends: [BaseSymbolInformation].} = object
      deprecated*: Option[bool]
      location*: Location

    CodeActionParams* {.extends: [WorkDoneProgressParams, PartialResultParams].} = object
      textDocument*: TextDocumentIdentifier
      `range`*: Range
      context*: CodeActionContext

    CodeActionContext* = object
      diagnostics*: OptionalSeq[Diagnostic]

    CodeLensParams* {.extends: [WorkDoneProgressParams, PartialResultParams].} = object
      textDocument*: TextDocumentIdentifier

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeLens
    CodeLens* = object
      `range`*: Range
      command*: Option[Command]
      data*: Option[LspAny]

    CodeLensRegistrationOptions* {.
      extends: [TextDocumentRegistrationOptions, CodeLensOptions]
    .} = object

    DocumentLinkParams* {.extends: [WorkDoneProgressParams, PartialResultParams].} = object
      textDocument*: TextDocumentIdentifier

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentLink
    DocumentLink* = object
      `range`*: Range
      target*: Option[string]
      data*: Option[LspAny]

    DocumentLinkRegistrationOptions* {.
      extends: [TextDocumentRegistrationOptions, DocumentLinkOptions]
    .} = object

    DocumentColorParams* {.extends: [WorkDoneProgressParams, PartialResultParams].} = object
      textDocument*: TextDocumentIdentifier

    ColorInformation* = object
      `range`*: Range
      color*: Color

    Color* = object
      red*: int
      green*: int
      blue*: int
      alpha*: int

    ColorPresentationParams* {.extends: [WorkDoneProgressParams, PartialResultParams].} = object
      textDocument*: TextDocumentIdentifier
      color*: Color
      `range`*: Range

    ColorPresentation* = object
      label*: string
      textEdit*: Option[TextEdit]
      additionalTextEdits*: OptionalSeq[TextEdit]

    FormattingOptions* = object
      tabSize*: uinteger
      insertSpaces*: bool
      trimTrailingWhitespace*: Option[bool]
      insertFinalNewline*: Option[bool]
      trimFinalNewlines*: Option[bool]

    DocumentFormattingParams* {.extends: [WorkDoneProgressParams].} = object
      textDocument*: TextDocumentIdentifier
      options*: FormattingOptions

    DocumentRangeFormattingParams* {.extends: [WorkDoneProgressParams].} = object
      textDocument*: TextDocumentIdentifier
      `range`*: Range
      options*: FormattingOptions

    DocumentOnTypeFormattingParams* = object
      textDocument*: TextDocumentIdentifier
      position*: Position
      ch*: string
      options*: FormattingOptions

    DocumentOnTypeFormattingRegistrationOptions* {.
      extends: [TextDocumentRegistrationOptions, DocumentOnTypeFormattingOptions]
    .} = object

    RenameParams* {.extends: [TextDocumentPositionParams, WorkDoneProgressParams].} = object
      newName*: string

    PrepareRenameParams* {.
      extends: [TextDocumentPositionParams, WorkDoneProgressParams]
    .} = object

    PrepareRenameResponse* = object
      defaultBehaviour*: bool

    SignatureHelpContext* = object
      triggerKind*: int
      triggerCharacter*: Option[string]
      isRetrigger*: bool
      activeSignatureHelp*: Option[SignatureHelp]

    SignatureHelpParams* {.
      extends: [TextDocumentPositionParams, WorkDoneProgressParams]
    .} = object
      context*: Option[SignatureHelpContext]

    ExpandResult* = object
      range*: Range
      content*: string

    InlayHintParams* {.extends: [WorkDoneProgressParams, PartialResultParams].} = object
      textDocument*: TextDocumentIdentifier
      range*: Range

    InlayHintKind_int* = int

    InlayHint* = object
      position*: Position
      label*: string # string | InlayHintLabelPart[]
      kind*: Option[InlayHintKind_int]
      textEdits*: OptionalSeq[TextEdit]
      tooltip*: Option[string] # string | MarkupContent
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

createJsonFlavor LspJson,
  automaticObjectSerialization = false,
  requireAllFields = true,
  omitOptionalFields = true,
  allowUnknownFields = true,
  skipNullFields = true

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

# XXX skipNullFields = false and remove this
func isFieldExpected*(
    _: type TextDocumentRegistrationOptionsDocumentSelector
): bool {.compileTime.} =
  false

LspJson.useOneOfSerializationFor(DiagnosticCode)
LspJson.useOneOfSerializationFor(ProgressToken)
LspJson.useOneOfSerializationFor(WorkspaceFoldersChangeNotifications)

LspJson.useDefaultSerializationFor(Position)
LspJson.useDefaultSerializationFor(Range)
LspJson.useDefaultSerializationFor(Location)
LspJson.useDefaultSerializationFor(Diagnostic)
LspJson.useDefaultSerializationFor(DiagnosticRelatedInformation)
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
LspJson.useDefaultReaderFor(McpListToolsParams)
LspJson.useDefaultReaderFor(McpCallToolParams)
LspJson.useDefaultReaderFor(McpInitializeParams_clientInfo_Icon)
LspJson.useDefaultReaderFor(McpInitializeParams_clientInfo)
LspJson.useDefaultReaderFor(LspInitializeParams_clientInfo)
LspJson.useDefaultReaderFor(McpInitializeParams)
LspJson.useDefaultReaderFor(LspInitializeParams)
LspJson.useDefaultReaderFor(InitializedParams)
LspJson.useDefaultReaderFor(SetTraceParams)
LspJson.useDefaultReaderFor(ChangeAnnotationSupportWorkspaceEditClientCapabilities)
LspJson.useDefaultReaderFor(WorkspaceEditClientCapabilities)
LspJson.useDefaultReaderFor(DidChangeConfigurationClientCapabilities)
LspJson.useDefaultReaderFor(DidChangeWatchedFilesClientCapabilities)
LspJson.useDefaultReaderFor(WorkspaceSymbolClientCapabilities_symbolKind)
LspJson.useDefaultReaderFor(WorkspaceSymbolClientCapabilities_tagSupport)
LspJson.useDefaultReaderFor(WorkspaceSymbolClientCapabilities_resolveSupport)
LspJson.useDefaultReaderFor(WorkspaceSymbolClientCapabilities)
LspJson.useDefaultReaderFor(ExecuteCommandClientCapabilities)
LspJson.useDefaultReaderFor(ClientCapabilities_workspace_fileOperations)
LspJson.useDefaultReaderFor(SemanticTokensWorkspaceClientCapabilities)
LspJson.useDefaultReaderFor(CodeLensWorkspaceClientCapabilities)
LspJson.useDefaultReaderFor(InlineValueWorkspaceClientCapabilities)
LspJson.useDefaultReaderFor(InlayHintWorkspaceClientCapabilities)
LspJson.useDefaultReaderFor(DiagnosticWorkspaceClientCapabilities)
LspJson.useDefaultReaderFor(ClientCapabilities_workspace)
LspJson.useDefaultReaderFor(TextDocumentSyncClientCapabilities)
LspJson.useDefaultReaderFor(CompletionClientCapabilities_completionItem_tagSupport)
LspJson.useDefaultReaderFor(CompletionClientCapabilities_completionItem_resolveSupport)
LspJson.useDefaultReaderFor(
  CompletionClientCapabilities_completionItem_insertTextModeSupport
)
LspJson.useDefaultReaderFor(CompletionClientCapabilities_completionItem)
LspJson.useDefaultReaderFor(CompletionClientCapabilities_completionItemKind)
LspJson.useDefaultReaderFor(CompletionClientCapabilities_completionList)
LspJson.useDefaultReaderFor(CompletionClientCapabilities)
LspJson.useDefaultReaderFor(HoverClientCapabilities)
LspJson.useDefaultReaderFor(
  SignatureHelpClientCapabilities_signatureInformation_parameterInformation
)
LspJson.useDefaultReaderFor(SignatureHelpClientCapabilities_signatureInformation)
LspJson.useDefaultReaderFor(SignatureHelpClientCapabilities)
LspJson.useDefaultReaderFor(ReferenceClientCapabilities)
LspJson.useDefaultReaderFor(DocumentHighlightClientCapabilities)
LspJson.useDefaultReaderFor(DocumentSymbolClientCapabilities_symbolKind)
LspJson.useDefaultReaderFor(DocumentSymbolClientCapabilities_tagSupport)
LspJson.useDefaultReaderFor(DocumentSymbolClientCapabilities)
LspJson.useDefaultReaderFor(DocumentFormattingClientCapabilities)
LspJson.useDefaultReaderFor(DocumentRangeFormattingClientCapabilities)
LspJson.useDefaultReaderFor(DocumentOnTypeFormattingClientCapabilities)
LspJson.useDefaultReaderFor(DefinitionClientCapabilities)
LspJson.useDefaultReaderFor(TypeDefinitionClientCapabilities)
LspJson.useDefaultReaderFor(ImplementationClientCapabilities)
LspJson.useDefaultReaderFor(
  CodeActionClientCapabilities_codeActionLiteralSupport_codeActionKind
)
LspJson.useDefaultReaderFor(CodeActionClientCapabilities_codeActionLiteralSupport)
LspJson.useDefaultReaderFor(CodeActionClientCapabilities_resolveSupport)
LspJson.useDefaultReaderFor(CodeActionClientCapabilities)
LspJson.useDefaultReaderFor(CodeLensClientCapabilities)
LspJson.useDefaultReaderFor(DocumentLinkClientCapabilities)
LspJson.useDefaultReaderFor(DocumentColorClientCapabilities)
LspJson.useDefaultReaderFor(RenameClientCapabilities)
LspJson.useDefaultReaderFor(PublishDiagnosticsClientCapabilities_tagSupport)
LspJson.useDefaultReaderFor(PublishDiagnosticsClientCapabilities)
LspJson.useDefaultReaderFor(DeclarationClientCapabilities)
LspJson.useDefaultReaderFor(FoldingRangeClientCapabilities_foldingRangeKind)
LspJson.useDefaultReaderFor(FoldingRangeClientCapabilities_foldingRange)
LspJson.useDefaultReaderFor(FoldingRangeClientCapabilities)
LspJson.useDefaultReaderFor(SelectionRangeClientCapabilities)
LspJson.useDefaultReaderFor(LinkedEditingRangeClientCapabilities)
LspJson.useDefaultReaderFor(CallHierarchyClientCapabilities)
LspJson.useDefaultSerializationFor(EmptyObject)
LspJson.useDefaultSerializationFor(ClientSemanticTokensRequestFullDelta)
LspJson.useOneOfSerializationFor(ClientSemanticTokensRequestRange)
LspJson.useOneOfSerializationFor(ClientSemanticTokensRequestFull)
LspJson.useDefaultReaderFor(ClientSemanticTokensRequestOptions)
LspJson.useDefaultReaderFor(SemanticTokensClientCapabilities)
LspJson.useDefaultReaderFor(MonikerClientCapabilities)
LspJson.useDefaultReaderFor(TypeHierarchyClientCapabilities)
LspJson.useDefaultReaderFor(InlineValueClientCapabilities)
LspJson.useDefaultReaderFor(InlayHintClientCapabilities_resolveSupport)
LspJson.useDefaultReaderFor(InlayHintClientCapabilities)
LspJson.useDefaultReaderFor(DiagnosticClientCapabilities)
LspJson.useDefaultReaderFor(TextDocumentClientCapabilities)
LspJson.useDefaultReaderFor(ShowMessageRequestClientCapabilities_messageActionItem)
LspJson.useDefaultReaderFor(ShowMessageRequestClientCapabilities)
LspJson.useDefaultReaderFor(ShowDocumentClientCapabilities)
LspJson.useDefaultReaderFor(ClientCapabilities_window)
LspJson.useDefaultReaderFor(NotebookDocumentSyncClientCapabilities)
LspJson.useDefaultReaderFor(NotebookDocumentClientCapabilities)
LspJson.useDefaultReaderFor(ClientCapabilities_general_staleRequestSupport)
LspJson.useDefaultReaderFor(RegularExpressionsClientCapabilities)
LspJson.useDefaultReaderFor(MarkdownClientCapabilities)
LspJson.useDefaultReaderFor(ClientCapabilities_general)
LspJson.useDefaultReaderFor(McpClientCapabilities)
LspJson.useDefaultReaderFor(LspClientCapabilities)
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
LspJson.useDefaultWriterFor(TextDocumentEdit)
LspJson.useDefaultWriterFor(WorkspaceEdit)
LspJson.useDefaultWriterFor(VersionedTextDocumentIdentifier)
LspJson.useDefaultWriterFor(WorkDoneProgressBegin)
LspJson.useDefaultWriterFor(WorkDoneProgressReport)
LspJson.useDefaultWriterFor(WorkDoneProgressEnd)
LspJson.useDefaultWriterFor(ProgressParams[WorkDoneProgressBegin])
LspJson.useDefaultWriterFor(ProgressParams[WorkDoneProgressReport])
LspJson.useDefaultWriterFor(ProgressParams[WorkDoneProgressEnd])
LspJson.useDefaultWriterFor(WorkDoneProgressCreateParams)
LspJson.useDefaultWriterFor(ConfigurationItem)
LspJson.useDefaultWriterFor(ConfigurationParams)
LspJson.useDefaultWriterFor(McpInitializeParams_serverInfo)
LspJson.useDefaultWriterFor(McpInitializeResult)
LspJson.useDefaultWriterFor(LspInitializeResult)
LspJson.useDefaultWriterFor(CompletionOptions)
LspJson.useDefaultWriterFor(SignatureHelpOptions)
LspJson.useDefaultWriterFor(CodeLensOptions)
LspJson.useDefaultWriterFor(DocumentOnTypeFormattingOptions)
LspJson.useDefaultWriterFor(DocumentLinkOptions)
LspJson.useDefaultWriterFor(ExecuteCommandOptions)
LspJson.useDefaultWriterFor(WorkspaceFoldersServerCapabilities)
LspJson.useDefaultWriterFor(ServerCapabilities_workspace)
LspJson.useDefaultWriterFor(InlayHintOptions)
LspJson.useDefaultWriterFor(McpToolSchema)
LspJson.useDefaultWriterFor(McpTool)
LspJson.useDefaultWriterFor(McpListToolsResult)
LspJson.useDefaultWriterFor(McpContentBlock)
LspJson.useDefaultWriterFor(McpCallToolResult)
LspJson.useDefaultWriterFor(McpToolsOptions)
LspJson.useDefaultWriterFor(McpServerCapabilities)
LspJson.useDefaultWriterFor(DocumentFilter)
LspJson.useOneOfWriterFor(TextDocumentRegistrationOptionsDocumentSelector)
LspJson.useDefaultWriterFor(SaveOptions)
LspJson.useDefaultWriterFor(TextDocumentSyncOptions)
LspJson.useDefaultWriterFor(RenameOptions)
LspJson.useDefaultWriterFor(ImplementationOptions)
LspJson.useDefaultWriterFor(ImplementationRegistrationOptions)
LspJson.useDefaultWriterFor(DocumentColorOptions)
LspJson.useDefaultWriterFor(DocumentColorRegistrationOptions)
LspJson.useOneOfWriterFor(ServerCapabilitiesTextDocumentSync)
LspJson.useOneOfWriterFor(ServerCapabilitiesImplementationProvider)
LspJson.useOneOfWriterFor(ServerCapabilitiesColorProvider)
LspJson.useOneOfWriterFor(ServerCapabilitiesRenameProvider)
LspJson.useDefaultWriterFor(LspServerCapabilities)
LspJson.useDefaultWriterFor(ShowMessageParams)
LspJson.useDefaultWriterFor(FileSystemWatcher)
LspJson.useDefaultWriterFor(DidChangeWatchedFilesRegistrationOptions)
LspJson.useDefaultWriterFor(Registration)
LspJson.useDefaultWriterFor(RegistrationParams)
LspJson.useDefaultWriterFor(ApplyWorkspaceEditParams)
LspJson.useDefaultReaderFor(ApplyWorkspaceEditResponse)
LspJson.useDefaultWriterFor(PublishDiagnosticsParams)
LspJson.useDefaultWriterFor(MarkupContent)
LspJson.useOneOfWriterFor(CompletionItemDocumentation)
LspJson.useDefaultWriterFor(CompletionItemLabelDetails)
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
