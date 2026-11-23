import std/sequtils, unittest2, ../protocol/[oneof, types]

type SelectorHolder = object
  documentSelector: Nullable[DocumentSelector]

LspJson.useDefaultReaderFor(DocumentFilter)
LspJson.useDefaultSerializationFor(SelectorHolder)
LspJson.useDefaultWriterFor(CodeLens)
LspJson.useDefaultWriterFor(DocumentLink)

suite "decoding cancel params":
  test "a number id is decoded as a number":
    let id = LspJson.decode("""{"id": 5}""", CancelParams).id
    check id.kind == riNumber and id.num == 5

  test "a string id is decoded as a string":
    let id = LspJson.decode("""{"id": "abc"}""", CancelParams).id
    check id.kind == riString and id.str == "abc"

  test "a missing id is rejected":
    expect SerializationError:
      discard LspJson.decode("{}", CancelParams)

suite "diagnostic code":
  test "a number code is decoded as a number":
    let code = LspJson.decode("5", DiagnosticCode)
    check code.kind == dgcNum and code.num == 5

  test "a string code is decoded as a string":
    let code = LspJson.decode("\"UnusedImport\"", DiagnosticCode)
    check code.kind == dgcStr and code.str == "UnusedImport"

  test "a code that is neither is rejected":
    expect SerializationError:
      discard LspJson.decode("true", DiagnosticCode)

  test "a code is encoded as a number or a string":
    check LspJson.encode(DiagnosticCode(kind: dgcNum, num: 5)) == "5"
    check LspJson.encode(DiagnosticCode(kind: dgcStr, str: "UnusedImport")) == "\"UnusedImport\""

suite "decoding a uinteger":
  test "0 and 2^31 - 1 are accepted":
    check LspJson.decode("0", uinteger).int == 0
    check LspJson.decode("2147483647", uinteger).int == 2147483647

  test "a negative value is rejected":
    expect SerializationError:
      discard LspJson.decode("-1", uinteger)

  test "a value above 2^31 - 1 is rejected":
    expect SerializationError:
      discard LspJson.decode("2147483648", uinteger)

  test "a position with an out of range field is rejected":
    expect SerializationError:
      discard LspJson.decode("""{"line": -1, "character": 0}""", Position)

  test "a uinteger is encoded as a number":
    check LspJson.encode(uinteger(5)) == "5"

suite "command":
  test "the arguments are written as they are":
    let command = Command(
      title: "Clean build",
      command: "nimlangserver.recompile",
      arguments: some @[JsonString("\"/a/hw.nim\""), JsonString("""{"n": 1}""")],
    )
    check LspJson.encode(command) ==
      """{"title":"Clean build","command":"nimlangserver.recompile","arguments":["/a/hw.nim",{"n": 1}]}"""

  test "no arguments leaves the field out":
    let command = Command(title: "t", command: "c")
    check LspJson.encode(command) == """{"title":"t","command":"c"}"""

suite "mcp notification params":
  test "the meta fields are kept as json, without whitespace":
    let params =
      LspJson.decode("""{"_meta": {"a": [1, 2], "b": "x"}}""", McpNotificationParams)
    let meta = params.meta.get
    check meta.len == 2
    check meta["a"].string == "[1,2]"
    check meta["b"].string == "\"x\""

  test "no meta decodes as none":
    check LspJson.decode("{}", McpNotificationParams).meta.isNone

suite "mcp tool call params":
  test "the arguments are kept as json, without whitespace":
    let params = LspJson.decode(
      """{"name": "nimFindReferences", "arguments": {"path": "/a/hw.nim", "line": 3}}""",
      McpCallToolRequestParams,
    )
    check params.arguments.get.string == """{"path":"/a/hw.nim","line":3}"""

  test "no arguments decodes as none":
    let params = LspJson.decode("""{"name": "nimCheckProject"}""", McpCallToolRequestParams)
    check params.arguments.isNone

suite "initialize params":
  test "the initialization options are kept as json":
    let params = LspJson.decode(
      """{"processId": 1, "rootUri": null, "capabilities": {}, "initializationOptions": {"a": [1]}}""",
      InitializeParams,
    )
    check params.initializationOptions.get.string == """{"a":[1]}"""
    check params.processId.kind == nkValue
    check params.processId.value == 1

  test "null initialization options decode as none":
    let params = LspJson.decode(
      """{"processId": null, "rootUri": null, "capabilities": {}, "initializationOptions": null}""",
      InitializeParams,
    )
    check params.initializationOptions.isNone
    check params.processId.kind == nkNull
    check params.rootUri.kind == nkNull

  test "the root uri is read":
    let params = LspJson.decode(
      """{"processId": null, "rootUri": "file:///a", "capabilities": {}}""",
      InitializeParams,
    )
    check params.rootUri.kind == nkValue
    check params.rootUri.value == LspUri("file:///a")

  test "the process id and the root uri are required, even though they can be null":
    expect SerializationError:
      discard LspJson.decode("""{"rootUri": null, "capabilities": {}}""", InitializeParams)
    expect SerializationError:
      discard LspJson.decode("""{"processId": null, "capabilities": {}}""", InitializeParams)

  test "null for an optional field decodes as none":
    let params = LspJson.decode(
      """{"processId": null, "rootUri": null, "rootPath": null, "workspaceFolders": null, "capabilities": {}}""",
      InitializeParams,
    )
    check params.rootPath.isNone
    check params.workspaceFolders.isNone

  test "null for a required field that cannot be null is rejected":
    expect SerializationError:
      discard LspJson.decode(
        """{"processId": null, "rootUri": null, "capabilities": null}""",
        InitializeParams,
      )

suite "did change configuration params":
  test "the settings are kept as json, without whitespace":
    let params = LspJson.decode(
      """{"settings": {"nim": {"projectMapping": []}}}""", DidChangeConfigurationParams
    )
    check params.settings.string == """{"nim":{"projectMapping":[]}}"""

  test "null settings are kept as null":
    let params = LspJson.decode("""{"settings": null}""", DidChangeConfigurationParams)
    check params.settings.string == "null"

  test "the settings are required":
    expect SerializationError:
      discard LspJson.decode("{}", DidChangeConfigurationParams)

suite "execute command params":
  test "the arguments are kept as json, without whitespace":
    let params = LspJson.decode(
      """{"command": "c", "arguments": ["a.nim", {"b": [1, 2]}]}""",
      ExecuteCommandParams,
    )
    check params.arguments.get.mapIt(it.string) == @["\"a.nim\"", """{"b":[1,2]}"""]

  test "no arguments decodes as none":
    check LspJson.decode("""{"command": "c"}""", ExecuteCommandParams).arguments.isNone

suite "completion item":
  test "the documentation is written as a string or as markup content":
    check LspJson.encode(
      CompletionItem(
        label: "echo",
        documentation: some CompletionItemDocumentation(kind: cidStr, str: "doc"),
      )
    ) == """{"label":"echo","documentation":"doc"}"""
    check LspJson.encode(
      CompletionItem(
        label: "echo",
        documentation: some CompletionItemDocumentation(
          kind: cidMarkup, markup: MarkupContent(kind: "markdown", value: "*doc*")
        ),
      )
    ) == """{"label":"echo","documentation":{"kind":"markdown","value":"*doc*"}}"""

  test "no documentation leaves the field out":
    check LspJson.encode(CompletionItem(label: "echo")) == """{"label":"echo"}"""

  test "the data is written as it is":
    check LspJson.encode(
      CompletionItem(label: "echo", data: some JsonString("""{"a":[1]}"""))
    ) == """{"label":"echo","data":{"a":[1]}}"""

suite "hover":
  test "the contents are written as markup content":
    let hover = Hover(
      contents: HoverContents(
        kind: hcMarkup, markup: MarkupContent(kind: "markdown", value: "*a*")
      )
    )
    check LspJson.encode(hover) ==
      """{"contents":{"kind":"markdown","value":"*a*"}}"""

  test "the contents are written as a marked string":
    let str = Hover(
      contents: HoverContents(
        kind: hcMarkedString, markedString: MarkedString(kind: msStr, str: "a")
      )
    )
    check LspJson.encode(str) == """{"contents":"a"}"""
    let option = Hover(
      contents: HoverContents(
        kind: hcMarkedString,
        markedString: MarkedString(
          kind: msOption, option: MarkedStringOption(language: "nim", value: "a")
        ),
      )
    )
    check LspJson.encode(option) == """{"contents":{"language":"nim","value":"a"}}"""

  test "the contents are written as marked strings":
    let hover = Hover(
      contents: HoverContents(
        kind: hcMarkedStrings,
        markedStrings: @[
          MarkedString(kind: msStr, str: "a"),
          MarkedString(
            kind: msOption, option: MarkedStringOption(language: "nim", value: "b")
          ),
        ],
      ),
      range: some Range(
        start: Position(line: uinteger 1, character: uinteger 2),
        `end`: Position(line: uinteger 1, character: uinteger 3),
      ),
    )
    check LspJson.encode(hover) ==
      """{"contents":["a",{"language":"nim","value":"b"}],"range":{"start":{"line":1,"character":2},"end":{"line":1,"character":3}}}"""

suite "code lens":
  test "the data is written as it is":
    let lens = CodeLens(
      range: Range(
        start: Position(line: uinteger 0, character: uinteger 0),
        `end`: Position(line: uinteger 0, character: uinteger 1),
      ),
      data: some JsonString("""{"a":[1]}"""),
    )
    check LspJson.encode(lens) ==
      """{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"data":{"a":[1]}}"""

suite "document link":
  test "the data is written as it is":
    let link = DocumentLink(
      range: Range(
        start: Position(line: uinteger 0, character: uinteger 0),
        `end`: Position(line: uinteger 0, character: uinteger 1),
      ),
      data: some JsonString("""{"a":[1]}"""),
    )
    check LspJson.encode(link) ==
      """{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"data":{"a":[1]}}"""

suite "document formatting params":
  test "the formatting options are read":
    let params = LspJson.decode(
      """{"textDocument": {"uri": "file:///a.nim"}, "options": {"tabSize": 2, "insertSpaces": true, "trimFinalNewlines": false}}""",
      DocumentFormattingParams,
    )
    check params.options.tabSize.int == 2
    check params.options.insertSpaces
    check params.options.trimTrailingWhitespace.isNone
    check params.options.insertFinalNewline.isNone
    check params.options.trimFinalNewlines == some false

  test "missing options are rejected":
    expect SerializationError:
      discard LspJson.decode(
        """{"textDocument": {"uri": "file:///a.nim"}}""", DocumentFormattingParams
      )

  test "options without a tab size are rejected":
    expect SerializationError:
      discard LspJson.decode(
        """{"textDocument": {"uri": "file:///a.nim"}, "options": {"insertSpaces": true}}""",
        DocumentFormattingParams,
      )

suite "extended params":
  test "the fields of every parent are read":
    let params = LspJson.decode(
      """{"textDocument": {"uri": "file:///a.nim"}, "position": {"line": 1, "character": 2}, "workDoneToken": 5, "partialResultToken": "p", "context": {"includeDeclaration": true}}""",
      ReferenceParams,
    )
    check params.textDocument.uri == LspUri("file:///a.nim")
    check params.position.line.int == 1
    check params.position.character.int == 2
    check params.workDoneToken.get.kind == ptNum
    check params.workDoneToken.get.num == 5
    check params.partialResultToken.get.kind == ptStr
    check params.partialResultToken.get.str == "p"
    check params.context.includeDeclaration

  test "a required field of a parent is required":
    expect SerializationError:
      discard LspJson.decode(
        """{"position": {"line": 1, "character": 2}}""", HoverParams
      )

  test "the version of a versioned text document is read":
    let identifier = LspJson.decode(
      """{"uri": "file:///a.nim", "version": 3}""", VersionedTextDocumentIdentifier
    )
    check identifier.uri == LspUri("file:///a.nim")
    check identifier.version == 3

  test "the version of a versioned text document is required":
    expect SerializationError:
      discard LspJson.decode("""{"uri": "file:///a.nim"}""", VersionedTextDocumentIdentifier)
    expect SerializationError:
      discard LspJson.decode(
        """{"uri": "file:///a.nim", "version": null}""", VersionedTextDocumentIdentifier
      )

  test "an edit writes the version of its document, or null":
    let edit = TextDocumentEdit(
      textDocument: OptionalVersionedTextDocumentIdentifier(uri: LspUri("file:///a.nim")),
      edits: @[TextDocumentEditEdit(kind: tdeeText, text: TextEdit(newText: "x"))],
    )
    check LspJson.encode(edit) ==
      """{"textDocument":{"uri":"file:///a.nim","version":null},"edits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"x"}]}"""
    let versioned = OptionalVersionedTextDocumentIdentifier(
      uri: LspUri("file:///a.nim"), version: Nullable[int](kind: nkValue, value: 2)
    )
    check LspJson.encode(versioned) == """{"uri":"file:///a.nim","version":2}"""

  test "a progress token is a number or a string":
    check LspJson.encode(ProgressToken(kind: ptNum, num: 1)) == "1"
    check LspJson.encode(ProgressToken(kind: ptStr, str: "t")) == "\"t\""
    expect SerializationError:
      discard LspJson.decode("true", ProgressToken)

suite "initialized params":
  test "an empty object is accepted":
    discard LspJson.decode("{}", InitializedParams)

  test "something that is not an object is rejected":
    expect SerializationError:
      discard LspJson.decode("[]", InitializedParams)

suite "work done progress":
  test "a begin carries its kind and title":
    let params = ProgressParams[WorkDoneProgressBegin](
      token: ProgressToken(kind: ptStr, str: "t"),
      value: WorkDoneProgressBegin(
        kind: "begin", title: "Checking", percentage: some uinteger(5)
      ),
    )
    check LspJson.encode(params) ==
      """{"token":"t","value":{"kind":"begin","title":"Checking","percentage":5}}"""

  test "a report leaves out what is not set":
    let params = ProgressParams[WorkDoneProgressReport](
      token: ProgressToken(kind: ptStr, str: "t"),
      value: WorkDoneProgressReport(kind: "report", message: some "half"),
    )
    check LspJson.encode(params) ==
      """{"token":"t","value":{"kind":"report","message":"half"}}"""

  test "an end has no title":
    let params = ProgressParams[WorkDoneProgressEnd](
      token: ProgressToken(kind: ptStr, str: "t"), value: WorkDoneProgressEnd(kind: "end")
    )
    check LspJson.encode(params) == """{"token":"t","value":{"kind":"end"}}"""

  test "creating a progress sends only the token":
    let params = WorkDoneProgressCreateParams(token: ProgressToken(kind: ptStr, str: "t"))
    check LspJson.encode(params) == """{"token":"t"}"""

  test "a number token is written as a number":
    let params = WorkDoneProgressCreateParams(token: ProgressToken(kind: ptNum, num: 7))
    check LspJson.encode(params) == """{"token":7}"""

suite "semantic tokens request options":
  test "a boolean and an object are both accepted":
    let options = LspJson.decode(
      """{"range": true, "full": {"delta": true}}""", ClientSemanticTokensRequestOptions
    )
    check options.range.get.kind == cstrBool and options.range.get.boolean
    check options.full.get.kind == cstfDelta and options.full.get.delta.delta == some true

  test "the empty object of range is accepted":
    let options = LspJson.decode(
      """{"range": {}, "full": false}""", ClientSemanticTokensRequestOptions
    )
    check options.range.get.kind == cstrEmpty
    check options.full.get.kind == cstfBool and not options.full.get.boolean

  test "neither is required":
    let options = LspJson.decode("{}", ClientSemanticTokensRequestOptions)
    check options.range.isNone and options.full.isNone

  test "something that is neither a boolean nor an object is rejected":
    expect SerializationError:
      discard LspJson.decode("""{"full": "yes"}""", ClientSemanticTokensRequestOptions)

  test "a boolean or an object is encoded as is":
    check LspJson.encode(ClientSemanticTokensRequestRange(kind: cstrBool, boolean: true)) ==
      "true"
    check LspJson.encode(
      ClientSemanticTokensRequestRange(kind: cstrEmpty, empty: EmptyObject())
    ) ==
      "{}"

suite "client capabilities":
  test "the experimental capabilities are kept as json":
    let capabilities = LspJson.decode(
      """{"experimental": {"snippetTextEdit": true}}""", ClientCapabilities
    )
    check capabilities.experimental.get.string == """{"snippetTextEdit":true}"""

suite "workspace folders server capabilities":
  test "change notifications can be a boolean":
    let capability = WorkspaceFoldersServerCapabilities(
      changeNotifications:
        some WorkspaceFoldersChangeNotifications(kind: wfcnBool, boolean: true)
    )
    check LspJson.encode(capability) == """{"changeNotifications":true}"""

  test "change notifications can be a registration id":
    let capability = WorkspaceFoldersServerCapabilities(
      changeNotifications:
        some WorkspaceFoldersChangeNotifications(kind: wfcnStr, str: "folders")
    )
    check LspJson.encode(capability) == """{"changeNotifications":"folders"}"""

  test "a string is read as a string":
    let value = LspJson.decode("\"folders\"", WorkspaceFoldersChangeNotifications)
    check value.kind == wfcnStr and value.str == "folders"

suite "unions":
  const zero = """{"start":{"line":0,"character":0},"end":{"line":0,"character":0}}"""

  test "a diagnostic message is a string or markup":
    let plain = Diagnostic(message: DiagnosticMessage(kind: dmStr, str: "m"))
    check LspJson.encode(plain) == """{"range":""" & zero & ""","message":"m"}"""
    let markup = Diagnostic(
      message: DiagnosticMessage(
        kind: dmMarkup, markup: MarkupContent(kind: "markdown", value: "*m*")
      )
    )
    check LspJson.encode(markup) ==
      """{"range":""" & zero & ""","message":{"kind":"markdown","value":"*m*"}}"""

  test "a diagnostic message is read as a string or markup":
    let plain =
      LspJson.decode("""{"range":""" & zero & ""","message":"m"}""", Diagnostic)
    check plain.message.kind == dmStr and plain.message.str == "m"
    let markup = LspJson.decode(
      """{"range":""" & zero & ""","message":{"kind":"markdown","value":"*m*"}}""",
      Diagnostic,
    )
    check markup.message.kind == dmMarkup and markup.message.markup.value == "*m*"

  test "a text document edit takes annotated and snippet edits":
    let edit = TextDocumentEdit(
      textDocument: OptionalVersionedTextDocumentIdentifier(uri: LspUri("file:///a.nim")),
      edits: @[
        TextDocumentEditEdit(
          kind: tdeeAnnotated,
          annotated: AnnotatedTextEdit(newText: "x", annotationId: "a"),
        ),
        TextDocumentEditEdit(
          kind: tdeeSnippet,
          snippet: SnippetTextEdit(snippet: StringValue(kind: "snippet", value: "$1")),
        ),
      ],
    )
    check LspJson.encode(edit) ==
      """{"textDocument":{"uri":"file:///a.nim","version":null},"edits":[{"range":""" &
      zero & ""","newText":"x","annotationId":"a"},{"range":""" & zero &
      ""","snippet":{"kind":"snippet","value":"$1"}}]}"""

  test "workspace edit document changes take file operations":
    let edit = WorkspaceEdit(
      documentChanges: some @[
        WorkspaceEditDocumentChange(
          kind: wedcCreate, create: CreateFile(kind: "create", uri: LspUri("file:///a.nim"))
        ),
        WorkspaceEditDocumentChange(
          kind: wedcRename,
          rename: RenameFile(
            kind: "rename", oldUri: LspUri("file:///a.nim"), newUri: LspUri("file:///b.nim")
          ),
        ),
        WorkspaceEditDocumentChange(
          kind: wedcDelete, delete: DeleteFile(kind: "delete", uri: LspUri("file:///b.nim"))
        ),
      ]
    )
    check LspJson.encode(edit) ==
      """{"documentChanges":[{"kind":"create","uri":"file:///a.nim"},{"kind":"rename","oldUri":"file:///a.nim","newUri":"file:///b.nim"},{"kind":"delete","uri":"file:///b.nim"}]}"""

  test "save is a boolean or save options":
    check LspJson.encode(
      TextDocumentSyncOptions(
        save: some TextDocumentSyncOptionsSave(kind: tdsosBool, boolean: true)
      )
    ) == """{"save":true}"""
    check LspJson.encode(
      TextDocumentSyncOptions(
        save: some TextDocumentSyncOptionsSave(
          kind: tdsosOptions, options: SaveOptions(includeText: some true)
        )
      )
    ) == """{"save":{"includeText":true}}"""

  test "a glob pattern is a pattern or a relative pattern":
    let relative = FileSystemWatcher(
      globPattern: GlobPattern(
        kind: gpRelative,
        relative: RelativePattern(
          baseUri: RelativePatternBaseUri(
            kind: rpbuFolder,
            folder: WorkspaceFolder(uri: LspUri("file:///w"), name: "w"),
          ),
          pattern: "*.nim",
        ),
      )
    )
    check LspJson.encode(relative) ==
      """{"globPattern":{"baseUri":{"uri":"file:///w","name":"w"},"pattern":"*.nim"}}"""
    let uri = RelativePattern(
      baseUri: RelativePatternBaseUri(kind: rpbuUri, uri: "file:///w"), pattern: "*.nim"
    )
    check LspJson.encode(uri) == """{"baseUri":"file:///w","pattern":"*.nim"}"""

  test "a parameter label is a string or offsets":
    let offsets = ParameterInformation(
      label: ParameterInformationLabel(
        kind: pilOffsets, offsets: [uinteger(1), uinteger(3)]
      )
    )
    check LspJson.encode(offsets) == """{"label":[1,3]}"""
    let decoded = LspJson.decode("""{"label":[1,3]}""", ParameterInformation)
    check decoded.label.offsets.mapIt(it.int) == @[1, 3]
    check LspJson.decode("""{"label":"p"}""", ParameterInformation).label.str == "p"

  test "an inlay hint label is a string or parts with tooltips":
    let hint = InlayHint(
      label: InlayHintLabel(
        kind: ihlParts,
        parts: @[
          InlayHintLabelPart(
            value: "v",
            tooltip: some InlayHintTooltip(
              kind: ihtMarkup, markup: MarkupContent(kind: "plaintext", value: "t")
            ),
          )
        ],
      ),
      tooltip: some InlayHintTooltip(kind: ihtStr, str: "s"),
    )
    check LspJson.encode(hint) ==
      """{"position":{"line":0,"character":0},"label":[{"value":"v","tooltip":{"kind":"plaintext","value":"t"}}],"tooltip":"s"}"""

  test "a provider is a boolean or its options":
    let capabilities = ServerCapabilities(
      hoverProvider: some ServerCapabilitiesHoverProvider(kind: shpBool, boolean: true),
      documentSymbolProvider: some ServerCapabilitiesDocumentSymbolProvider(
        kind: sdspOptions, options: DocumentSymbolOptions(label: some "nim")
      ),
      inlayHintProvider: some ServerCapabilitiesInlayHintProvider(
        kind: sihpRegistration,
        registration: InlayHintRegistrationOptions(id: some "hints"),
      ),
    )
    check LspJson.encode(capabilities) ==
      """{"hoverProvider":true,"documentSymbolProvider":{"label":"nim"},"inlayHintProvider":{"documentSelector":null,"id":"hints"}}"""

suite "spec field names":
  test "the completion documentation formats are read":
    let options = LspJson.decode(
      """{"documentationFormat": ["markdown"]}""", ClientCompletionItemOptions
    )
    check options.documentationFormat == some @["markdown"]

  test "the active signature is a uinteger":
    let help = SignatureHelp(signatures: @[], activeSignature: some uinteger(0))
    check LspJson.encode(help) == """{"signatures":[],"activeSignature":0}"""

suite "mcp initialize":
  test "the request params read the meta and the client icons":
    let params = LspJson.decode(
      """{"_meta": {"progressToken": 1}, "protocolVersion": "v", "capabilities": {},
      "clientInfo": {"name": "c", "version": "1", "icons": [{"src": "x", "theme": "dark"}]}}""",
      McpInitializeRequestParams,
    )
    check params.meta.isSome
    check params.clientInfo.name == "c"
    check params.clientInfo.icons.get[0].theme == some dark

  test "the client info requires a name and a version":
    expect SerializationError:
      discard LspJson.decode(
        """{"protocolVersion": "v", "capabilities": {}, "clientInfo": {"name": "c"}}""",
        McpInitializeRequestParams,
      )

  test "the server info leaves out what is not set":
    let res = McpInitializeResult(
      protocolVersion: "v",
      capabilities: McpServerCapabilities(tools: some McpToolsOptions()),
      serverInfo: McpImplementation(name: "n", version: "1"),
    )
    check LspJson.encode(res) ==
      """{"protocolVersion":"v","capabilities":{"tools":{}},"serverInfo":{"name":"n","version":"1"}}"""

suite "mcp tool":
  test "the title and the description are optional":
    let tool = McpTool(name: "t", inputSchema: McpToolSchema(`type`: "object"))
    check LspJson.encode(tool) == """{"name":"t","inputSchema":{"type":"object"}}"""

  test "the base metadata comes first":
    let tool = McpTool(
      name: "t",
      title: some "T",
      description: some "d",
      inputSchema: McpToolSchema(`type`: "object"),
    )
    check LspJson.encode(tool) ==
      """{"name":"t","title":"T","description":"d","inputSchema":{"type":"object"}}"""

suite "mcp tool call result":
  test "the structured content is written as it is":
    let res = McpCallToolResult(
      content: @[McpContentBlock(`type`: TextContent, text: """{"refs":[]}""")],
      structuredContent: some JsonString("""{"refs":[]}"""),
    )
    check LspJson.encode(res) ==
      """{"content":[{"type":"text","text":"{\"refs\":[]}"}],"structuredContent":{"refs":[]}}"""

  test "no structured content leaves the field out":
    let res = McpCallToolResult(
      content: @[McpContentBlock(`type`: TextContent, text: "x")], isError: some true
    )
    check LspJson.encode(res) ==
      """{"content":[{"type":"text","text":"x"}],"isError":true}"""

suite "server capabilities":
  test "text document sync is written as its options or its kind":
    let options = ServerCapabilities(
      textDocumentSync: some ServerCapabilitiesTextDocumentSync(
        kind: stdsOptions,
        options: TextDocumentSyncOptions(openClose: some true, change: some 1),
      )
    )
    check LspJson.encode(options) ==
      """{"textDocumentSync":{"openClose":true,"change":1}}"""
    let kind = ServerCapabilities(
      textDocumentSync:
        some ServerCapabilitiesTextDocumentSync(kind: stdsKind, syncKind: 2)
    )
    check LspJson.encode(kind) == """{"textDocumentSync":2}"""

  test "rename is written as a boolean or its options":
    let boolean = ServerCapabilities(
      renameProvider: some ServerCapabilitiesRenameProvider(kind: srpBool, boolean: true)
    )
    check LspJson.encode(boolean) == """{"renameProvider":true}"""
    let options = ServerCapabilities(
      renameProvider: some ServerCapabilitiesRenameProvider(
        kind: srpOptions, options: RenameOptions(prepareProvider: some true)
      )
    )
    check LspJson.encode(options) == """{"renameProvider":{"prepareProvider":true}}"""

  test "a registration option writes the document selector it inherits":
    let capabilities = ServerCapabilities(
      implementationProvider: some ServerCapabilitiesImplementationProvider(
        kind: sipRegistration,
        registration: ImplementationRegistrationOptions(
          documentSelector: Nullable[DocumentSelector](
            kind: nkValue, value: @[DocumentFilter(language: some "nim")]
          ),
          id: some "impl",
        ),
      ),
      colorProvider: some ServerCapabilitiesColorProvider(kind: scpBool, boolean: false),
    )
    check LspJson.encode(capabilities) ==
      """{"implementationProvider":{"documentSelector":[{"language":"nim"}],"id":"impl"},"colorProvider":false}"""

  test "the experimental capabilities are written as they are":
    let capabilities =
      ServerCapabilities(experimental: some JsonString("""{"x":1}"""))
    check LspJson.encode(capabilities) == """{"experimental":{"x":1}}"""

suite "nullable":
  test "a Nullable is the value or null":
    check LspJson.encode(Nullable[int](kind: nkValue, value: 3)) == "3"
    check LspJson.encode(Nullable[int]()) == "null"
    check LspJson.decode("3", Nullable[int]).value == 3
    check LspJson.decode("null", Nullable[int]).kind == nkNull
    expect SerializationError:
      discard LspJson.decode("\"x\"", Nullable[int])

suite "document selector":
  test "a registration without a document selector writes null":
    let options = ImplementationRegistrationOptions(id: some "impl")
    check LspJson.encode(options) == """{"documentSelector":null,"id":"impl"}"""

  test "a document selector is written as its filters":
    let holder = SelectorHolder(
      documentSelector: Nullable[DocumentSelector](
        kind: nkValue, value: @[DocumentFilter(scheme: some "file")]
      )
    )
    check LspJson.encode(holder) == """{"documentSelector":[{"scheme":"file"}]}"""

  test "null is read as the null member":
    let holder = LspJson.decode("""{"documentSelector": null}""", SelectorHolder)
    check holder.documentSelector.kind == nkNull

  test "a missing document selector is rejected":
    expect SerializationError:
      discard LspJson.decode("{}", SelectorHolder)

  test "filters are read as the selector member":
    let holder =
      LspJson.decode("""{"documentSelector": [{"language": "nim"}]}""", SelectorHolder)
    check holder.documentSelector.kind == nkValue
    check holder.documentSelector.value[0].language == some "nim"

suite "registration":
  test "the register options are written as they are":
    let registration = Registration(
      id: "watch",
      `method`: "workspace/didChangeWatchedFiles",
      registerOptions: some JsonString("""{"watchers":[{"globPattern":"**/*.nim"}]}"""),
    )
    check LspJson.encode(registration) ==
      """{"id":"watch","method":"workspace/didChangeWatchedFiles","registerOptions":{"watchers":[{"globPattern":"**/*.nim"}]}}"""

  test "watched files options are encoded with their watchers":
    let options = DidChangeWatchedFilesRegistrationOptions(
      watchers: @[
        FileSystemWatcher(
          globPattern: GlobPattern(kind: gpPattern, pattern: "**/*.nim"), kind: some 7
        )
      ]
    )
    check LspJson.encode(options) ==
      """{"watchers":[{"globPattern":"**/*.nim","kind":7}]}"""
