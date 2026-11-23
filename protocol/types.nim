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
      relatedInformation*: OptionalSeq[DiagnosticRelatedInformation]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#diagnosticRelatedInformation
    DiagnosticRelatedInformation* = object
      location*: Location
      message*: string

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

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#changeAnnotationIdentifier
    ChangeAnnotationIdentifier* = string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#annotatedTextEdit
    AnnotatedTextEdit* {.extends: [TextEdit].} = object
      annotationId*: ChangeAnnotationIdentifier

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#stringValue
    StringValue* = object
      kind*: string
      value*: string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#snippetTextEdit
    SnippetTextEdit* = object
      `range`*: Range
      snippet*: StringValue
      annotationId*: Option[ChangeAnnotationIdentifier]

    TextDocumentEditEditKind* = enum
      tdeeText
      tdeeAnnotated
      tdeeSnippet

    TextDocumentEditEdit* = object
      case kind*: TextDocumentEditEditKind
      of tdeeText:
        text*: TextEdit
      of tdeeAnnotated:
        annotated*: AnnotatedTextEdit
      of tdeeSnippet:
        snippet*: SnippetTextEdit

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentEdit
    TextDocumentEdit* = object
      textDocument*: OptionalVersionedTextDocumentIdentifier
      edits*: seq[TextDocumentEditEdit]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#createFile
    CreateFile* = object
      kind*: string
      uri*: DocumentUri
      annotationId*: Option[ChangeAnnotationIdentifier]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#renameFile
    RenameFile* = object
      kind*: string
      oldUri*: DocumentUri
      newUri*: DocumentUri
      annotationId*: Option[ChangeAnnotationIdentifier]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#deleteFile
    DeleteFile* = object
      kind*: string
      uri*: DocumentUri
      annotationId*: Option[ChangeAnnotationIdentifier]

    WorkspaceEditDocumentChangeKind* = enum
      wedcEdit
      wedcCreate
      wedcRename
      wedcDelete

    WorkspaceEditDocumentChange* = object
      case kind*: WorkspaceEditDocumentChangeKind
      of wedcEdit:
        edit*: TextDocumentEdit
      of wedcCreate:
        create*: CreateFile
      of wedcRename:
        rename*: RenameFile
      of wedcDelete:
        delete*: DeleteFile

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceEdit
    WorkspaceEdit* = object
      changes*: Option[Table[DocumentUri, seq[TextEdit]]]
      documentChanges*: OptionalSeq[WorkspaceEditDocumentChange]

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

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#optionalVersionedTextDocumentIdentifier
    OptionalVersionedTextDocumentIdentifier* {.extends: [TextDocumentIdentifier].} = object
      version*: Nullable[int]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentPositionParams
    TextDocumentPositionParams* = object
      textDocument*: TextDocumentIdentifier
      position*: Position

    ExpandTextDocumentPositionParams* {.extends: [TextDocumentPositionParams].} = object
      level*: Option[int]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentFilter
    DocumentFilter* = object
      language*: Option[string]
      scheme*: Option[string]
      pattern*: Option[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#markupContent
    MarkupContent* = object
      kind*: string
      value*: string

    # https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2025-11-25/schema.ts#L73
    McpNotificationParams* = object
      meta* {.serializedFieldName: "_meta".}: Option[OrderedTable[string, JsonString]]

    # https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2025-11-25/schema.ts#L51
    McpRequestParams* = object
      meta* {.serializedFieldName: "_meta".}: Option[OrderedTable[string, JsonString]]

    # https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2025-11-25/schema.ts#L35
    McpTaskAugmentedRequestParams* {.extends: [McpRequestParams].} = object

    # https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2025-11-25/schema.ts#L627
    McpPaginatedRequestParams* {.extends: [McpRequestParams].} = object

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#calltoolrequestparams
    McpCallToolRequestParams* {.extends: [McpTaskAugmentedRequestParams].} = object
      name*: string
      arguments*: Option[JsonString]

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#result
    McpResult* = object
      meta* {.serializedFieldName: "_meta".}: Option[OrderedTable[string, JsonString]]

    # https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2025-11-25/schema.ts#L641
    McpPaginatedResult* {.extends: [McpResult].} = object

    McpIconTheme* = enum
      light = "light"
      dark = "dark"

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#icon
    McpIcon* = object
      src*: string
      mimeType*: Option[string]
      sizes*: OptionalSeq[string]
      theme*: Option[McpIconTheme]

    # https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2025-11-25/schema.ts#L508
    McpIcons* = object
      icons*: OptionalSeq[McpIcon]

    # https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2025-11-25/schema.ts#L528
    McpBaseMetadata* = object
      name*: string
      title*: Option[string]

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#implementation
    McpImplementation* {.extends: [McpBaseMetadata, McpIcons].} = object
      version*: string
      description*: Option[string]
      websiteUrl*: Option[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientInfo
    ClientInfo* = object
      name*: string
      version*: Option[string]

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#initializerequestparams
    McpInitializeRequestParams* {.extends: [McpRequestParams].} = object
      protocolVersion*: string
      capabilities*: McpClientCapabilities
      clientInfo*: McpImplementation

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initializeParams
    InitializeParams* {.extends: [WorkDoneProgressParams].} = object
      processId*: Nullable[int]
      clientInfo*: Option[ClientInfo]
      locale*: Option[string]
      rootPath*: Option[string]
      rootUri*: Nullable[DocumentUri]
      initializationOptions*: Option[LspAny]
      capabilities*: ClientCapabilities
      trace*: Option[string]
      workspaceFolders*: OptionalSeq[WorkspaceFolder]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#setTrace
    SetTraceParams* = object
      value*: string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workDoneProgressBegin
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
      workDoneToken*: Option[ProgressToken]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#partialResultParams
    PartialResultParams* = object
      partialResultToken*: Option[ProgressToken]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workDoneProgressOptions
    WorkDoneProgressOptions* = object
      workDoneProgress*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workDoneProgressBegin
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
      token*: ProgressToken
      value*: T

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_workDoneProgress_create
    WorkDoneProgressCreateParams* = object
      token*: ProgressToken

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#configurationItem
    ConfigurationItem* = object
      scopeUri*: Option[string]
      section*: Option[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#configurationParams
    ConfigurationParams* = object
      items*: seq[ConfigurationItem]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#changeAnnotationsSupportOptions
    ChangeAnnotationsSupportOptions* = object
      groupsOnLabel*: Option[bool]

    # 'create' | 'rename' | 'delete'
    ResourceOperationKind = string

    # 'abort' | 'transactional' | 'undo' | 'textOnlyTransactional'
    FailureHandlingKind = string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceEditClientCapabilities
    WorkspaceEditClientCapabilities* = object
      documentChanges*: Option[bool]
      resourceOperations*: OptionalSeq[ResourceOperationKind]
      failureHandling*: Option[FailureHandlingKind]
      normalizesLineEndings*: Option[bool]
      changeAnnotationSupport*: Option[ChangeAnnotationsSupportOptions]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#didChangeConfigurationClientCapabilities
    DidChangeConfigurationClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#didChangeWatchedFilesClientCapabilities
    DidChangeWatchedFilesClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      relativePatternSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientSymbolResolveOptions
    ClientSymbolResolveOptions* = object
      properties*: seq[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_symbol
    WorkspaceSymbolClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      symbolKind*: Option[ClientSymbolKindOptions]
      tagSupport*: Option[ClientSymbolTagOptions]
      resolveSupport*: Option[ClientSymbolResolveOptions]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#executeCommandClientCapabilities
    ExecuteCommandClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#fileOperationClientCapabilities
    FileOperationClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      didCreate*: Option[bool]
      willCreate*: Option[bool]
      didRename*: Option[bool]
      willRename*: Option[bool]
      didDelete*: Option[bool]
      willDelete*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokensWorkspaceClientCapabilities
    SemanticTokensWorkspaceClientCapabilities* = object
      refreshSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeLensWorkspaceClientCapabilities
    CodeLensWorkspaceClientCapabilities* = object
      refreshSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlineValueWorkspaceClientCapabilities
    InlineValueWorkspaceClientCapabilities* = object
      refreshSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlayHintWorkspaceClientCapabilities
    InlayHintWorkspaceClientCapabilities* = object
      refreshSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#diagnosticWorkspaceClientCapabilities
    DiagnosticWorkspaceClientCapabilities* = object
      refreshSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceClientCapabilities
    WorkspaceClientCapabilities* = object
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
      fileOperations*: Option[FileOperationClientCapabilities]
      inlineValue*: Option[InlineValueWorkspaceClientCapabilities]
      inlayHint*: Option[InlayHintWorkspaceClientCapabilities]
      diagnostics*: Option[DiagnosticWorkspaceClientCapabilities]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentSyncClientCapabilities
    TextDocumentSyncClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      willSave*: Option[bool]
      willSaveWaitUntil*: Option[bool]
      didSave*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionItemTagOptions
    CompletionItemTagOptions* = object
      valueSet*: seq[int]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientCompletionItemResolveOptions
    ClientCompletionItemResolveOptions* = object
      properties*: seq[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientCompletionItemInsertTextModeOptions
    ClientCompletionItemInsertTextModeOptions* = object
      valueSet*: seq[int]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientCompletionItemOptions
    ClientCompletionItemOptions* = object
      snippetSupport*: Option[bool]
      commitCharactersSupport*: Option[bool]
      documentationFormat*: OptionalSeq[string]
      deprecatedSupport*: Option[bool]
      preselectSupport*: Option[bool]
      tagSupport*: Option[CompletionItemTagOptions]
      insertReplaceSupport*: Option[bool]
      resolveSupport*: Option[ClientCompletionItemResolveOptions]
      insertTextModeSupport*: Option[ClientCompletionItemInsertTextModeOptions]
      labelDetailsSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientCompletionItemOptionsKind
    ClientCompletionItemOptionsKind* = object
      valueSet*: OptionalSeq[int]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionListCapabilities
    CompletionListCapabilities* = object
      itemDefaults*: OptionalSeq[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionClientCapabilities
    CompletionClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      completionItem*: Option[ClientCompletionItemOptions]
      completionItemKind*: Option[ClientCompletionItemOptionsKind]
      contextSupport*: Option[bool]
      insertTextMode*: Option[int]
      completionList*: Option[CompletionListCapabilities]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#hoverClientCapabilities
    HoverClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      contentFormat*: OptionalSeq[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientSignatureParameterInformationOptions
    ClientSignatureParameterInformationOptions* = object
      labelOffsetSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientSignatureInformationOptions
    ClientSignatureInformationOptions* = object
      documentationFormat*: OptionalSeq[string]
      parameterInformation*: Option[ClientSignatureParameterInformationOptions]
      activeParameterSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#signatureHelpClientCapabilities
    SignatureHelpClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      signatureInformation*: Option[ClientSignatureInformationOptions]
      contextSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#referenceClientCapabilities
    ReferenceClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentHighlightClientCapabilities
    DocumentHighlightClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientSymbolKindOptions
    ClientSymbolKindOptions* = object
      valueSet*: OptionalSeq[int]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientSymbolTagOptions
    ClientSymbolTagOptions* = object
      valueSet*: seq[int]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentSymbolClientCapabilities
    DocumentSymbolClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      symbolKind*: Option[ClientSymbolKindOptions]
      hierarchicalDocumentSymbolSupport*: Option[bool]
      tagSupport*: Option[ClientSymbolTagOptions]
      labelSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentFormattingClientCapabilities
    DocumentFormattingClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentRangeFormattingClientCapabilities
    DocumentRangeFormattingClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentOnTypeFormattingClientCapabilities
    DocumentOnTypeFormattingClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#definitionClientCapabilities
    DefinitionClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      linkSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#typeDefinitionClientCapabilities
    TypeDefinitionClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      linkSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#implementationClientCapabilities
    ImplementationClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      linkSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientCodeActionKindOptions
    ClientCodeActionKindOptions* = object
      valueSet*: seq[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientCodeActionLiteralOptions
    ClientCodeActionLiteralOptions* = object
      codeActionKind*: ClientCodeActionKindOptions

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientCodeActionResolveOptions
    ClientCodeActionResolveOptions* = object
      properties*: seq[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeActionClientCapabilities
    CodeActionClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      codeActionLiteralSupport*: Option[ClientCodeActionLiteralOptions]
      isPreferredSupport*: Option[bool]
      disabledSupport*: Option[bool]
      dataSupport*: Option[bool]
      resolveSupport*: Option[ClientCodeActionResolveOptions]
      honorsChangeAnnotations*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeLensClientCapabilities
    CodeLensClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentLinkClientCapabilities
    DocumentLinkClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      tooltipSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentColorClientCapabilities
    DocumentColorClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#renameClientCapabilities
    RenameClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      prepareSupport*: Option[bool]
      prepareSupportDefaultBehavior*: Option[int]
      honorsChangeAnnotations*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientDiagnosticsTagOptions
    ClientDiagnosticsTagOptions* = object
      valueSet*: seq[int]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#publishDiagnosticsClientCapabilities
    PublishDiagnosticsClientCapabilities* = object
      relatedInformation*: Option[bool]
      tagSupport*: Option[ClientDiagnosticsTagOptions]
      versionSupport*: Option[bool]
      codeDescriptionSupport*: Option[bool]
      dataSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#declarationClientCapabilities
    DeclarationClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      linkSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientFoldingRangeKindOptions
    ClientFoldingRangeKindOptions* = object
      valueSet*: OptionalSeq[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientFoldingRangeOptions
    ClientFoldingRangeOptions* = object
      collapsedText*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#foldingRangeClientCapabilities
    FoldingRangeClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      rangeLimit*: Option[uinteger]
      lineFoldingOnly*: Option[bool]
      foldingRangeKind*: Option[ClientFoldingRangeKindOptions]
      foldingRange*: Option[ClientFoldingRangeOptions]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#selectionRangeClientCapabilities
    SelectionRangeClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#linkedEditingRangeClientCapabilities
    LinkedEditingRangeClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#callHierarchyClientCapabilities
    CallHierarchyClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientSemanticTokensRequestOptions
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

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokensClientCapabilities
    SemanticTokensClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      requests*: ClientSemanticTokensRequestOptions
      tokenTypes*: seq[string]
      tokenModifiers*: seq[string]
      formats*: seq[string]
      overlappingTokenSupport*: Option[bool]
      multilineTokenSupport*: Option[bool]
      serverCancelSupport*: Option[bool]
      augmentsSyntaxTokens*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#monikerClientCapabilities
    MonikerClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#typeHierarchyClientCapabilities
    TypeHierarchyClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlineValueClientCapabilities
    InlineValueClientCapabilities* = object
      dynamicRegistration*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientInlayHintResolveOptions
    ClientInlayHintResolveOptions* = object
      properties*: seq[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlayHintClientCapabilities
    InlayHintClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      resolveSupport*: Option[ClientInlayHintResolveOptions]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#diagnosticClientCapabilities
    DiagnosticClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      relatedDocumentSupport*: Option[bool]
      relatedInformation*: Option[bool]
      tagSupport*: Option[ClientDiagnosticsTagOptions]
      codeDescriptionSupport*: Option[bool]
      dataSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentClientCapabilities
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

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientShowMessageActionItemOptions
    ClientShowMessageActionItemOptions* = object
      additionalPropertiesSupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_showMessageRequest
    ShowMessageRequestClientCapabilities* = object
      messageActionItem*: Option[ClientShowMessageActionItemOptions]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_showDocument
    ShowDocumentClientCapabilities* = object
      support*: bool

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#windowClientCapabilities
    WindowClientCapabilities* = object
      workDoneProgress*: Option[bool]
      showMessage*: Option[ShowMessageRequestClientCapabilities]
      showDocument*: Option[ShowDocumentClientCapabilities]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookDocumentSyncClientCapabilities
    NotebookDocumentSyncClientCapabilities* = object
      dynamicRegistration*: Option[bool]
      executionSummarySupport*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookDocumentClientCapabilities
    NotebookDocumentClientCapabilities* = object
      synchronization*: NotebookDocumentSyncClientCapabilities

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#staleRequestSupportOptions
    StaleRequestSupportOptions* = object
      cancel*: bool
      retryOnContentModified*: seq[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#regExp
    RegularExpressionsClientCapabilities* = object
      engine*: string
      version*: Option[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#markdownClientCapabilities
    MarkdownClientCapabilities* = object
      parser*: string
      version*: Option[string]
      allowedTags*: OptionalSeq[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#generalClientCapabilities
    GeneralClientCapabilities* = object
      staleRequestSupport*: Option[StaleRequestSupportOptions]
      regularExpressions*: Option[RegularExpressionsClientCapabilities]
      markdown*: Option[MarkdownClientCapabilities]
      positionEncodings*: OptionalSeq[string]

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#clientcapabilities
    McpClientCapabilities* = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientCapabilities
    ClientCapabilities* = object
      workspace*: Option[WorkspaceClientCapabilities]
      textDocument*: Option[TextDocumentClientCapabilities]
      notebookDocument*: Option[NotebookDocumentClientCapabilities]
      window*: Option[WindowClientCapabilities]
      general*: Option[GeneralClientCapabilities]
      experimental*: Option[LspAny]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceFolder
    WorkspaceFolder* = object
      uri*: LspUri
      name*: string

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#initializeresult
    McpInitializeResult* {.extends: [McpResult].} = object
      protocolVersion*: string
      capabilities*: McpServerCapabilities
      serverInfo*: McpImplementation

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initializeResult
    InitializeResult* = object
      capabilities*: ServerCapabilities

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initializeError
    InitializeError* = object
      retry*: bool

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionOptions
    CompletionOptions* {.extends: [WorkDoneProgressOptions].} = object
      resolveProvider*: Option[bool]
      triggerCharacters*: OptionalSeq[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#signatureHelpOptions
    SignatureHelpOptions* {.extends: [WorkDoneProgressOptions].} = object
      triggerCharacters*: OptionalSeq[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeLensOptions
    CodeLensOptions* {.extends: [WorkDoneProgressOptions].} = object
      resolveProvider*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentOnTypeFormattingOptions
    DocumentOnTypeFormattingOptions* = object
      firstTriggerCharacter*: string
      moreTriggerCharacter*: OptionalSeq[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentLinkOptions
    DocumentLinkOptions* {.extends: [WorkDoneProgressOptions].} = object
      resolveProvider*: Option[bool]

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

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#fileOperationPatternOptions
    FileOperationPatternOptions* = object
      ignoreCase*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#fileOperationPattern
    FileOperationPattern* = object
      glob*: string
      matches*: Option[string]
      options*: Option[FileOperationPatternOptions]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#fileOperationFilter
    FileOperationFilter* = object
      scheme*: Option[string]
      pattern*: FileOperationPattern

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#fileOperationRegistrationOptions
    FileOperationRegistrationOptions* = object
      filters*: seq[FileOperationFilter]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#fileOperationOptions
    FileOperationOptions* = object
      didCreate*: Option[FileOperationRegistrationOptions]
      willCreate*: Option[FileOperationRegistrationOptions]
      didRename*: Option[FileOperationRegistrationOptions]
      willRename*: Option[FileOperationRegistrationOptions]
      didDelete*: Option[FileOperationRegistrationOptions]
      willDelete*: Option[FileOperationRegistrationOptions]

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

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#implementationOptions
    ImplementationOptions* {.extends: [WorkDoneProgressOptions].} = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#implementationRegistrationOptions
    ImplementationRegistrationOptions* {.
      extends: [
        TextDocumentRegistrationOptions, ImplementationOptions,
        StaticRegistrationOptions,
      ]
    .} = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentColorOptions
    DocumentColorOptions* {.extends: [WorkDoneProgressOptions].} = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentColorRegistrationOptions
    DocumentColorRegistrationOptions* {.
      extends: [
        TextDocumentRegistrationOptions, StaticRegistrationOptions, DocumentColorOptions
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
        syncKind*: int

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

    ServerCapabilitiesHoverProviderKind* = enum
      shpBool
      shpOptions

    ServerCapabilitiesHoverProvider* = object
      case kind*: ServerCapabilitiesHoverProviderKind
      of shpBool:
        boolean*: bool
      of shpOptions:
        options*: HoverOptions

    ServerCapabilitiesDeclarationProviderKind* = enum
      sdeclpBool
      sdeclpOptions
      sdeclpRegistration

    ServerCapabilitiesDeclarationProvider* = object
      case kind*: ServerCapabilitiesDeclarationProviderKind
      of sdeclpBool:
        boolean*: bool
      of sdeclpOptions:
        options*: DeclarationOptions
      of sdeclpRegistration:
        registration*: DeclarationRegistrationOptions

    ServerCapabilitiesDefinitionProviderKind* = enum
      sdefpBool
      sdefpOptions

    ServerCapabilitiesDefinitionProvider* = object
      case kind*: ServerCapabilitiesDefinitionProviderKind
      of sdefpBool:
        boolean*: bool
      of sdefpOptions:
        options*: DefinitionOptions

    ServerCapabilitiesTypeDefinitionProviderKind* = enum
      stdpBool
      stdpOptions
      stdpRegistration

    ServerCapabilitiesTypeDefinitionProvider* = object
      case kind*: ServerCapabilitiesTypeDefinitionProviderKind
      of stdpBool:
        boolean*: bool
      of stdpOptions:
        options*: TypeDefinitionOptions
      of stdpRegistration:
        registration*: TypeDefinitionRegistrationOptions

    ServerCapabilitiesReferencesProviderKind* = enum
      srefpBool
      srefpOptions

    ServerCapabilitiesReferencesProvider* = object
      case kind*: ServerCapabilitiesReferencesProviderKind
      of srefpBool:
        boolean*: bool
      of srefpOptions:
        options*: ReferenceOptions

    ServerCapabilitiesDocumentHighlightProviderKind* = enum
      sdhpBool
      sdhpOptions

    ServerCapabilitiesDocumentHighlightProvider* = object
      case kind*: ServerCapabilitiesDocumentHighlightProviderKind
      of sdhpBool:
        boolean*: bool
      of sdhpOptions:
        options*: DocumentHighlightOptions

    ServerCapabilitiesDocumentSymbolProviderKind* = enum
      sdspBool
      sdspOptions

    ServerCapabilitiesDocumentSymbolProvider* = object
      case kind*: ServerCapabilitiesDocumentSymbolProviderKind
      of sdspBool:
        boolean*: bool
      of sdspOptions:
        options*: DocumentSymbolOptions

    ServerCapabilitiesWorkspaceSymbolProviderKind* = enum
      swspBool
      swspOptions

    ServerCapabilitiesWorkspaceSymbolProvider* = object
      case kind*: ServerCapabilitiesWorkspaceSymbolProviderKind
      of swspBool:
        boolean*: bool
      of swspOptions:
        options*: WorkspaceSymbolOptions

    ServerCapabilitiesCodeActionProviderKind* = enum
      scapBool
      scapOptions

    ServerCapabilitiesCodeActionProvider* = object
      case kind*: ServerCapabilitiesCodeActionProviderKind
      of scapBool:
        boolean*: bool
      of scapOptions:
        options*: CodeActionOptions

    ServerCapabilitiesDocumentFormattingProviderKind* = enum
      sdfpBool
      sdfpOptions

    ServerCapabilitiesDocumentFormattingProvider* = object
      case kind*: ServerCapabilitiesDocumentFormattingProviderKind
      of sdfpBool:
        boolean*: bool
      of sdfpOptions:
        options*: DocumentFormattingOptions

    ServerCapabilitiesDocumentRangeFormattingProviderKind* = enum
      sdrfpBool
      sdrfpOptions

    ServerCapabilitiesDocumentRangeFormattingProvider* = object
      case kind*: ServerCapabilitiesDocumentRangeFormattingProviderKind
      of sdrfpBool:
        boolean*: bool
      of sdrfpOptions:
        options*: DocumentRangeFormattingOptions

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

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#hoverOptions
    HoverOptions* {.extends: [WorkDoneProgressOptions].} = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#declarationOptions
    DeclarationOptions* {.extends: [WorkDoneProgressOptions].} = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#declarationRegistrationOptions
    DeclarationRegistrationOptions* {.
      extends:
        [DeclarationOptions, TextDocumentRegistrationOptions, StaticRegistrationOptions]
    .} = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#definitionOptions
    DefinitionOptions* {.extends: [WorkDoneProgressOptions].} = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#typeDefinitionOptions
    TypeDefinitionOptions* {.extends: [WorkDoneProgressOptions].} = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#typeDefinitionRegistrationOptions
    TypeDefinitionRegistrationOptions* {.
      extends: [
        TextDocumentRegistrationOptions, TypeDefinitionOptions,
        StaticRegistrationOptions,
      ]
    .} = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#referenceOptions
    ReferenceOptions* {.extends: [WorkDoneProgressOptions].} = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentHighlightOptions
    DocumentHighlightOptions* {.extends: [WorkDoneProgressOptions].} = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentSymbolOptions
    DocumentSymbolOptions* {.extends: [WorkDoneProgressOptions].} = object
      label*: Option[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceSymbolOptions
    WorkspaceSymbolOptions* {.extends: [WorkDoneProgressOptions].} = object
      resolveProvider*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeActionOptions
    CodeActionOptions* {.extends: [WorkDoneProgressOptions].} = object
      codeActionKinds*: OptionalSeq[string]
      resolveProvider*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentFormattingOptions
    DocumentFormattingOptions* {.extends: [WorkDoneProgressOptions].} = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentRangeFormattingOptions
    DocumentRangeFormattingOptions* {.extends: [WorkDoneProgressOptions].} = object
      rangesSupport*: Option[bool]

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

    # https://modelcontextprotocol.io/specification/2025-11-25/schema#tool
    McpToolSchema* = object
      schema* {.serializedFieldName: "$schema".}: Option[string]
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

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#serverCapabilities
    ServerCapabilities* = object #!!!positionEncoding*: Option[string]
      textDocumentSync*: Option[ServerCapabilitiesTextDocumentSync]
      #notebookDocumentSync?: NotebookDocumentSyncOptions | NotebookDocumentSyncRegistrationOptions;
      completionProvider*: Option[CompletionOptions]
      hoverProvider*: Option[ServerCapabilitiesHoverProvider]
      signatureHelpProvider*: Option[SignatureHelpOptions]
      declarationProvider*: Option[ServerCapabilitiesDeclarationProvider]
      definitionProvider*: Option[ServerCapabilitiesDefinitionProvider]
      typeDefinitionProvider*: Option[ServerCapabilitiesTypeDefinitionProvider]
      implementationProvider*: Option[ServerCapabilitiesImplementationProvider]
      referencesProvider*: Option[ServerCapabilitiesReferencesProvider]
      documentHighlightProvider*: Option[ServerCapabilitiesDocumentHighlightProvider]
      documentSymbolProvider*: Option[ServerCapabilitiesDocumentSymbolProvider]
      workspaceSymbolProvider*: Option[ServerCapabilitiesWorkspaceSymbolProvider]
      codeActionProvider*: Option[ServerCapabilitiesCodeActionProvider]
      codeLensProvider*: Option[CodeLensOptions]
      documentLinkProvider*: Option[DocumentLinkOptions]
      colorProvider*: Option[ServerCapabilitiesColorProvider]
      documentFormattingProvider*: Option[ServerCapabilitiesDocumentFormattingProvider]
      documentRangeFormattingProvider*:
        Option[ServerCapabilitiesDocumentRangeFormattingProvider]
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
      inlayHintProvider*: Option[ServerCapabilitiesInlayHintProvider]
      # diagnosticProvider?: DiagnosticOptions | DiagnosticRegistrationOptions;
      workspace*: Option[WorkspaceOptions]
      experimental*: Option[LspAny]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initialized
    InitializedParams* = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_showMessage
    ShowMessageParams* = object
      `type`*: int
      message*: string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#messageActionItem
    MessageActionItem* = object
      title*: string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#showMessageRequestParams
    ShowMessageRequestParams* = object
      `type`*: int
      message*: string
      actions*: OptionalSeq[MessageActionItem]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#logMessageParams
    LogMessageParams* = object
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

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#unregistration
    Unregistration* = object
      id*: string
      `method`*: string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#unregistrationParams
    UnregistrationParams* = object
      unregisterations*: seq[Unregistration]

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
        uri*: string

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

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#executeCommandRegistrationOptions
    ExecuteCommandRegistrationOptions* {.extends: [ExecuteCommandOptions].} = object

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
      rangeLength*: Option[int]
      text*: string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentChangeRegistrationOptions
    TextDocumentChangeRegistrationOptions* {.
      extends: [TextDocumentRegistrationOptions]
    .} = object
      syncKind*: int

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#willSaveTextDocumentParams
    WillSaveTextDocumentParams* = object
      textDocument*: TextDocumentIdentifier
      reason*: int

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#didSaveTextDocumentParams
    DidSaveTextDocumentParams* = object
      textDocument*: TextDocumentIdentifier
      text*: Option[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentSaveRegistrationOptions
    TextDocumentSaveRegistrationOptions* {.extends: [TextDocumentRegistrationOptions].} = object
      includeText*: Option[bool]

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
      triggerCharacter*: Option[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionList
    CompletionList* = object
      isIncomplete*: bool
      `items`*: seq[CompletionItem]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionItemLabelDetails
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

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionItem
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

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionRegistrationOptions
    CompletionRegistrationOptions* {.
      extends: [TextDocumentRegistrationOptions, CompletionOptions]
    .} = object

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

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#signatureHelpRegistrationOptions
    SignatureHelpRegistrationOptions* {.
      extends: [TextDocumentRegistrationOptions, SignatureHelpOptions]
    .} = object

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
      tags*: OptionalSeq[int]
      deprecated*: Option[bool]
      location*: Location
      containerName*: Option[string]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeActionParams
    CodeActionParams* {.extends: [WorkDoneProgressParams, PartialResultParams].} = object
      textDocument*: TextDocumentIdentifier
      `range`*: Range
      context*: CodeActionContext

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeActionContext
    CodeActionContext* = object
      diagnostics*: seq[Diagnostic]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeLensParams
    CodeLensParams* {.extends: [WorkDoneProgressParams, PartialResultParams].} = object
      textDocument*: TextDocumentIdentifier

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeLens
    CodeLens* = object
      `range`*: Range
      command*: Option[Command]
      data*: Option[LspAny]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeLensRegistrationOptions
    CodeLensRegistrationOptions* {.
      extends: [TextDocumentRegistrationOptions, CodeLensOptions]
    .} = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentLinkParams
    DocumentLinkParams* {.extends: [WorkDoneProgressParams, PartialResultParams].} = object
      textDocument*: TextDocumentIdentifier

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentLink
    DocumentLink* = object
      `range`*: Range
      target*: Option[string]
      data*: Option[LspAny]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentLinkRegistrationOptions
    DocumentLinkRegistrationOptions* {.
      extends: [TextDocumentRegistrationOptions, DocumentLinkOptions]
    .} = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentColorParams
    DocumentColorParams* {.extends: [WorkDoneProgressParams, PartialResultParams].} = object
      textDocument*: TextDocumentIdentifier

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#colorInformation
    ColorInformation* = object
      `range`*: Range
      color*: Color

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#color
    Color* = object
      red*: float
      green*: float
      blue*: float
      alpha*: float

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#colorPresentationParams
    ColorPresentationParams* {.extends: [WorkDoneProgressParams, PartialResultParams].} = object
      textDocument*: TextDocumentIdentifier
      color*: Color
      `range`*: Range

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#colorPresentation
    ColorPresentation* = object
      label*: string
      textEdit*: Option[TextEdit]
      additionalTextEdits*: OptionalSeq[TextEdit]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#formattingOptions
    FormattingOptions* = object
      tabSize*: uinteger
      insertSpaces*: bool
      trimTrailingWhitespace*: Option[bool]
      insertFinalNewline*: Option[bool]
      trimFinalNewlines*: Option[bool]

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentFormattingParams
    DocumentFormattingParams* {.extends: [WorkDoneProgressParams].} = object
      textDocument*: TextDocumentIdentifier
      options*: FormattingOptions

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentRangeFormattingParams
    DocumentRangeFormattingParams* {.extends: [WorkDoneProgressParams].} = object
      textDocument*: TextDocumentIdentifier
      `range`*: Range
      options*: FormattingOptions

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentOnTypeFormattingParams
    DocumentOnTypeFormattingParams* = object
      textDocument*: TextDocumentIdentifier
      position*: Position
      ch*: string
      options*: FormattingOptions

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentOnTypeFormattingRegistrationOptions
    DocumentOnTypeFormattingRegistrationOptions* {.
      extends: [TextDocumentRegistrationOptions, DocumentOnTypeFormattingOptions]
    .} = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#renameParams
    RenameParams* {.extends: [TextDocumentPositionParams, WorkDoneProgressParams].} = object
      newName*: string

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#prepareRenameParams
    PrepareRenameParams* {.
      extends: [TextDocumentPositionParams, WorkDoneProgressParams]
    .} = object

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#prepareRenameDefaultBehavior
    PrepareRenameDefaultBehavior* = object
      defaultBehavior*: bool

    # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#signatureHelpContext
    SignatureHelpContext* = object
      triggerKind*: int
      triggerCharacter*: Option[string]
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
LspJson.useDefaultReaderFor(McpPaginatedRequestParams)
LspJson.useDefaultReaderFor(McpCallToolRequestParams)
LspJson.useDefaultReaderFor(McpIcon)
LspJson.useDefaultReaderFor(McpImplementation)
LspJson.useDefaultReaderFor(ClientInfo)
LspJson.useDefaultReaderFor(McpInitializeRequestParams)
LspJson.useDefaultReaderFor(InitializeParams)
LspJson.useDefaultReaderFor(InitializedParams)
LspJson.useDefaultReaderFor(SetTraceParams)
LspJson.useDefaultReaderFor(ChangeAnnotationsSupportOptions)
LspJson.useDefaultReaderFor(WorkspaceEditClientCapabilities)
LspJson.useDefaultReaderFor(DidChangeConfigurationClientCapabilities)
LspJson.useDefaultReaderFor(DidChangeWatchedFilesClientCapabilities)
LspJson.useDefaultReaderFor(ClientSymbolKindOptions)
LspJson.useDefaultReaderFor(ClientSymbolTagOptions)
LspJson.useDefaultReaderFor(ClientSymbolResolveOptions)
LspJson.useDefaultReaderFor(WorkspaceSymbolClientCapabilities)
LspJson.useDefaultReaderFor(ExecuteCommandClientCapabilities)
LspJson.useDefaultReaderFor(FileOperationClientCapabilities)
LspJson.useDefaultReaderFor(SemanticTokensWorkspaceClientCapabilities)
LspJson.useDefaultReaderFor(CodeLensWorkspaceClientCapabilities)
LspJson.useDefaultReaderFor(InlineValueWorkspaceClientCapabilities)
LspJson.useDefaultReaderFor(InlayHintWorkspaceClientCapabilities)
LspJson.useDefaultReaderFor(DiagnosticWorkspaceClientCapabilities)
LspJson.useDefaultReaderFor(WorkspaceClientCapabilities)
LspJson.useDefaultReaderFor(TextDocumentSyncClientCapabilities)
LspJson.useDefaultReaderFor(CompletionItemTagOptions)
LspJson.useDefaultReaderFor(ClientCompletionItemResolveOptions)
LspJson.useDefaultReaderFor(ClientCompletionItemInsertTextModeOptions)
LspJson.useDefaultReaderFor(ClientCompletionItemOptions)
LspJson.useDefaultReaderFor(ClientCompletionItemOptionsKind)
LspJson.useDefaultReaderFor(CompletionListCapabilities)
LspJson.useDefaultReaderFor(CompletionClientCapabilities)
LspJson.useDefaultReaderFor(HoverClientCapabilities)
LspJson.useDefaultReaderFor(ClientSignatureParameterInformationOptions)
LspJson.useDefaultReaderFor(ClientSignatureInformationOptions)
LspJson.useDefaultReaderFor(SignatureHelpClientCapabilities)
LspJson.useDefaultReaderFor(ReferenceClientCapabilities)
LspJson.useDefaultReaderFor(DocumentHighlightClientCapabilities)
LspJson.useDefaultReaderFor(DocumentSymbolClientCapabilities)
LspJson.useDefaultReaderFor(DocumentFormattingClientCapabilities)
LspJson.useDefaultReaderFor(DocumentRangeFormattingClientCapabilities)
LspJson.useDefaultReaderFor(DocumentOnTypeFormattingClientCapabilities)
LspJson.useDefaultReaderFor(DefinitionClientCapabilities)
LspJson.useDefaultReaderFor(TypeDefinitionClientCapabilities)
LspJson.useDefaultReaderFor(ImplementationClientCapabilities)
LspJson.useDefaultReaderFor(ClientCodeActionKindOptions)
LspJson.useDefaultReaderFor(ClientCodeActionLiteralOptions)
LspJson.useDefaultReaderFor(ClientCodeActionResolveOptions)
LspJson.useDefaultReaderFor(CodeActionClientCapabilities)
LspJson.useDefaultReaderFor(CodeLensClientCapabilities)
LspJson.useDefaultReaderFor(DocumentLinkClientCapabilities)
LspJson.useDefaultReaderFor(DocumentColorClientCapabilities)
LspJson.useDefaultReaderFor(RenameClientCapabilities)
LspJson.useDefaultReaderFor(ClientDiagnosticsTagOptions)
LspJson.useDefaultReaderFor(PublishDiagnosticsClientCapabilities)
LspJson.useDefaultReaderFor(DeclarationClientCapabilities)
LspJson.useDefaultReaderFor(ClientFoldingRangeKindOptions)
LspJson.useDefaultReaderFor(ClientFoldingRangeOptions)
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
LspJson.useDefaultReaderFor(ClientInlayHintResolveOptions)
LspJson.useDefaultReaderFor(InlayHintClientCapabilities)
LspJson.useDefaultReaderFor(DiagnosticClientCapabilities)
LspJson.useDefaultReaderFor(TextDocumentClientCapabilities)
LspJson.useDefaultReaderFor(ClientShowMessageActionItemOptions)
LspJson.useDefaultReaderFor(ShowMessageRequestClientCapabilities)
LspJson.useDefaultReaderFor(ShowDocumentClientCapabilities)
LspJson.useDefaultReaderFor(WindowClientCapabilities)
LspJson.useDefaultReaderFor(NotebookDocumentSyncClientCapabilities)
LspJson.useDefaultReaderFor(NotebookDocumentClientCapabilities)
LspJson.useDefaultReaderFor(StaleRequestSupportOptions)
LspJson.useDefaultReaderFor(RegularExpressionsClientCapabilities)
LspJson.useDefaultReaderFor(MarkdownClientCapabilities)
LspJson.useDefaultReaderFor(GeneralClientCapabilities)
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
LspJson.useDefaultWriterFor(AnnotatedTextEdit)
LspJson.useDefaultWriterFor(StringValue)
LspJson.useDefaultWriterFor(SnippetTextEdit)
LspJson.useOneOfWriterFor(TextDocumentEditEdit)
LspJson.useDefaultWriterFor(OptionalVersionedTextDocumentIdentifier)
LspJson.useDefaultWriterFor(TextDocumentEdit)
LspJson.useDefaultWriterFor(CreateFile)
LspJson.useDefaultWriterFor(RenameFile)
LspJson.useDefaultWriterFor(DeleteFile)
LspJson.useOneOfWriterFor(WorkspaceEditDocumentChange)
LspJson.useDefaultWriterFor(WorkspaceEdit)
LspJson.useDefaultWriterFor(WorkDoneProgressBegin)
LspJson.useDefaultWriterFor(WorkDoneProgressReport)
LspJson.useDefaultWriterFor(WorkDoneProgressEnd)
LspJson.useDefaultWriterFor(ProgressParams[WorkDoneProgressBegin])
LspJson.useDefaultWriterFor(ProgressParams[WorkDoneProgressReport])
LspJson.useDefaultWriterFor(ProgressParams[WorkDoneProgressEnd])
LspJson.useDefaultWriterFor(WorkDoneProgressCreateParams)
LspJson.useDefaultWriterFor(ConfigurationItem)
LspJson.useDefaultWriterFor(ConfigurationParams)
LspJson.useDefaultWriterFor(McpImplementation)
LspJson.useDefaultWriterFor(McpIcon)
LspJson.useDefaultWriterFor(McpInitializeResult)
LspJson.useDefaultWriterFor(InitializeResult)
LspJson.useDefaultWriterFor(CompletionOptions)
LspJson.useDefaultWriterFor(SignatureHelpOptions)
LspJson.useDefaultWriterFor(CodeLensOptions)
LspJson.useDefaultWriterFor(DocumentOnTypeFormattingOptions)
LspJson.useDefaultWriterFor(DocumentLinkOptions)
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
LspJson.useDefaultWriterFor(ImplementationOptions)
LspJson.useDefaultWriterFor(ImplementationRegistrationOptions)
LspJson.useDefaultWriterFor(DocumentColorOptions)
LspJson.useDefaultWriterFor(DocumentColorRegistrationOptions)
LspJson.useOneOfWriterFor(ServerCapabilitiesTextDocumentSync)
LspJson.useOneOfWriterFor(ServerCapabilitiesImplementationProvider)
LspJson.useOneOfWriterFor(ServerCapabilitiesColorProvider)
LspJson.useOneOfWriterFor(ServerCapabilitiesRenameProvider)
LspJson.useDefaultWriterFor(WorkspaceFolder)
LspJson.useOneOfWriterFor(RelativePatternBaseUri)
LspJson.useDefaultWriterFor(RelativePattern)
LspJson.useOneOfWriterFor(GlobPattern)
LspJson.useOneOfWriterFor(InlayHintTooltip)
LspJson.useDefaultWriterFor(InlayHintLabelPart)
LspJson.useOneOfWriterFor(InlayHintLabel)
LspJson.useDefaultWriterFor(HoverOptions)
LspJson.useDefaultWriterFor(DeclarationOptions)
LspJson.useDefaultWriterFor(DeclarationRegistrationOptions)
LspJson.useDefaultWriterFor(DefinitionOptions)
LspJson.useDefaultWriterFor(TypeDefinitionOptions)
LspJson.useDefaultWriterFor(TypeDefinitionRegistrationOptions)
LspJson.useDefaultWriterFor(ReferenceOptions)
LspJson.useDefaultWriterFor(DocumentHighlightOptions)
LspJson.useDefaultWriterFor(DocumentSymbolOptions)
LspJson.useDefaultWriterFor(WorkspaceSymbolOptions)
LspJson.useDefaultWriterFor(CodeActionOptions)
LspJson.useDefaultWriterFor(DocumentFormattingOptions)
LspJson.useDefaultWriterFor(DocumentRangeFormattingOptions)
LspJson.useDefaultWriterFor(InlayHintRegistrationOptions)
LspJson.useOneOfWriterFor(ServerCapabilitiesHoverProvider)
LspJson.useOneOfWriterFor(ServerCapabilitiesDeclarationProvider)
LspJson.useOneOfWriterFor(ServerCapabilitiesDefinitionProvider)
LspJson.useOneOfWriterFor(ServerCapabilitiesTypeDefinitionProvider)
LspJson.useOneOfWriterFor(ServerCapabilitiesReferencesProvider)
LspJson.useOneOfWriterFor(ServerCapabilitiesDocumentHighlightProvider)
LspJson.useOneOfWriterFor(ServerCapabilitiesDocumentSymbolProvider)
LspJson.useOneOfWriterFor(ServerCapabilitiesWorkspaceSymbolProvider)
LspJson.useOneOfWriterFor(ServerCapabilitiesCodeActionProvider)
LspJson.useOneOfWriterFor(ServerCapabilitiesDocumentFormattingProvider)
LspJson.useOneOfWriterFor(ServerCapabilitiesDocumentRangeFormattingProvider)
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
