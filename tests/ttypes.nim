import std/sequtils, unittest2, ../protocol/[oneof, types]

type SelectorHolder = object
  documentSelector: Nullable[DocumentSelector]

LspJson.useDefaultReaderFor(DocumentFilter)
LspJson.useDefaultSerializationFor(SelectorHolder)

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
  test "the process id is ignored, whether a number, null or missing":
    for json in [
      """{"processId": 1, "capabilities": {}}""",
      """{"processId": null, "capabilities": {}}""", """{"capabilities": {}}""",
    ]:
      checkpoint json
      discard LspJson.decode(json, InitializeParams)

  test "a null root uri is read as none":
    let params = LspJson.decode(
      """{"processId": null, "rootUri": null, "capabilities": {}}""", InitializeParams
    )
    check params.rootUri.isNone

  test "the root uri is read":
    let params = LspJson.decode(
      """{"processId": null, "rootUri": "file:///a", "capabilities": {}}""",
      InitializeParams,
    )
    check params.rootUri == some LspUri("file:///a")

  test "the deprecated root uri can be left out":
    let params =
      LspJson.decode("""{"processId": null, "capabilities": {}}""", InitializeParams)
    check params.rootUri.isNone

  test "the capabilities are required":
    expect SerializationError:
      discard LspJson.decode("""{"processId": null, "rootUri": null}""", InitializeParams)

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

suite "document formatting params":
  test "the formatting options are read":
    let params = LspJson.decode(
      """{"textDocument": {"uri": "file:///a.nim"}, "options": {"tabSize": 2, "insertSpaces": true, "trimFinalNewlines": false}}""",
      DocumentFormattingParams,
    )
    check params.options.tabSize.int == 2
    check params.options.insertSpaces

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
      value: WorkDoneProgressBegin(kind: "begin", title: "Checking"),
    )
    check LspJson.encode(params) ==
      """{"token":"t","value":{"kind":"begin","title":"Checking"}}"""

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
      baseUri: RelativePatternBaseUri(kind: rpbuUri, uri: LspUri("file:///w")),
      pattern: "*.nim",
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
      hoverProvider: some true,
      inlayHintProvider: some ServerCapabilitiesInlayHintProvider(
        kind: sihpRegistration,
        registration: InlayHintRegistrationOptions(id: some "hints"),
      ),
    )
    check LspJson.encode(capabilities) ==
      """{"hoverProvider":true,"inlayHintProvider":{"documentSelector":null,"id":"hints"}}"""

suite "spec field names":
  test "the active signature is a uinteger":
    let help = SignatureHelp(signatures: @[], activeSignature: some uinteger(0))
    check LspJson.encode(help) == """{"signatures":[],"activeSignature":0}"""

suite "mcp initialize":
  test "the request params read the client info":
    let params = LspJson.decode(
      """{"protocolVersion": "v", "capabilities": {}, "clientInfo": {"name": "c", "version": "1"}}""",
      McpInitializeRequestParams,
    )
    check params.clientInfo.name == "c"

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
      inlayHintProvider: some ServerCapabilitiesInlayHintProvider(
        kind: sihpRegistration,
        registration: InlayHintRegistrationOptions(
          documentSelector: Nullable[DocumentSelector](
            kind: nkValue,
            value: @[
              DocumentFilter(
                pattern: some GlobPattern(kind: gpPattern, pattern: "**/*.nim")
              )
            ],
          ),
          id: some "hints",
        ),
      )
    )
    check LspJson.encode(capabilities) ==
      """{"inlayHintProvider":{"documentSelector":[{"pattern":"**/*.nim"}],"id":"hints"}}"""

suite "nullable":
  test "a Nullable is the value or null":
    check LspJson.encode(Nullable[int](kind: nkValue, value: 3)) == "3"
    check LspJson.encode(Nullable[int]()) == "null"
    check LspJson.decode("3", Nullable[int]).value == 3
    check LspJson.decode("null", Nullable[int]).kind == nkNull
    expect SerializationError:
      discard LspJson.decode("\"x\"", Nullable[int])

suite "document filter":
  test "a pattern is written as a glob or a relative pattern":
    let glob = DocumentFilter(
      pattern: some GlobPattern(kind: gpPattern, pattern: "**/*.nim")
    )
    check LspJson.encode(glob) == """{"pattern":"**/*.nim"}"""
    let relative = DocumentFilter(
      pattern: some GlobPattern(
        kind: gpRelative,
        relative: RelativePattern(
          baseUri: RelativePatternBaseUri(kind: rpbuUri, uri: LspUri("file:///w")),
          pattern: "*.nim",
        ),
      )
    )
    check LspJson.encode(relative) ==
      """{"pattern":{"baseUri":"file:///w","pattern":"*.nim"}}"""

  test "a pattern is read as a glob or a relative pattern":
    let glob = LspJson.decode("""{"pattern": "**/*.nim"}""", DocumentFilter)
    check glob.pattern.get.kind == gpPattern
    check glob.pattern.get.pattern == "**/*.nim"
    let relative = LspJson.decode(
      """{"pattern": {"baseUri": {"uri": "file:///w", "name": "w"}, "pattern": "*.nim"}}""",
      DocumentFilter,
    )
    check relative.pattern.get.kind == gpRelative
    check relative.pattern.get.relative.baseUri.kind == rpbuFolder
    check relative.pattern.get.relative.pattern == "*.nim"

suite "document selector":
  test "a registration without a document selector writes null":
    let options = InlayHintRegistrationOptions(id: some "hints")
    check LspJson.encode(options) == """{"documentSelector":null,"id":"hints"}"""

  test "a document selector is written as its filters":
    let holder = SelectorHolder(
      documentSelector: Nullable[DocumentSelector](
        kind: nkValue,
        value: @[DocumentFilter(pattern: some GlobPattern(kind: gpPattern, pattern: "*.nim"))],
      )
    )
    check LspJson.encode(holder) == """{"documentSelector":[{"pattern":"*.nim"}]}"""

  test "null is read as the null member":
    let holder = LspJson.decode("""{"documentSelector": null}""", SelectorHolder)
    check holder.documentSelector.kind == nkNull

  test "a missing document selector is rejected":
    expect SerializationError:
      discard LspJson.decode("{}", SelectorHolder)

  test "filters are read as the selector member":
    let holder =
      LspJson.decode("""{"documentSelector": [{"pattern": "*.nim"}]}""", SelectorHolder)
    check holder.documentSelector.kind == nkValue
    check holder.documentSelector.value[0].pattern.get.pattern == "*.nim"

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

const
  zeroRange = """{"start":{"line":0,"character":0},"end":{"line":0,"character":0}}"""
  aRange = """{"start":{"line":1,"character":2},"end":{"line":3,"character":4}}"""
  docPos = """"textDocument": {"uri": "file:///a.nim"}, "position": {"line": 1, "character": 2}"""

proc `==`(a, b: uinteger): bool {.borrow.}

func pos(line, character: int): Position =
  Position(line: uinteger line, character: uinteger character)

func rng(): Range =
  Range(start: pos(1, 2), `end`: pos(3, 4))

suite "lsp uri":
  test "a file uri is read":
    check LspJson.decode("\"file:///a.nim\"", LspUri) == LspUri("file:///a.nim")

  test "a uri that is not a file uri is rejected":
    expect SerializationError:
      discard LspJson.decode("\"http:///a.nim\"", LspUri)

  test "a file uri with a host is rejected":
    expect SerializationError:
      discard LspJson.decode("\"file://host/a.nim\"", LspUri)

  test "a uri is written as a string":
    check LspJson.encode(LspUri("file:///a.nim")) == "\"file:///a.nim\""

suite "position, range and location":
  test "a range is read and written":
    check LspJson.encode(rng()) == aRange
    check LspJson.decode(aRange, Range) == rng()

  test "a position requires the line and the character":
    expect SerializationError:
      discard LspJson.decode("""{"line": 1}""", Position)
    expect SerializationError:
      discard LspJson.decode("""{"character": 1}""", Position)

  test "a location is read and written":
    let location = Location(uri: LspUri("file:///a.nim"), range: rng())
    let json = """{"uri":"file:///a.nim","range":""" & aRange & "}"
    check LspJson.encode(location) == json
    check LspJson.decode(json, Location) == location

  test "a location requires the uri and the range":
    expect SerializationError:
      discard LspJson.decode("""{"uri": "file:///a.nim"}""", Location)
    expect SerializationError:
      discard LspJson.decode("""{"range": """ & aRange & "}", Location)

suite "diagnostic":
  test "every field is written":
    let diagnostic = Diagnostic(
      range: rng(),
      severity: some 1,
      code: some DiagnosticCode(kind: dgcStr, str: "c"),
      source: some "nim",
      message: DiagnosticMessage(kind: dmStr, str: "m"),
    )
    check LspJson.encode(diagnostic) ==
      """{"range":""" & aRange & ""","severity":1,"code":"c","source":"nim","message":"m"}"""

  test "every field is read":
    let diagnostic = LspJson.decode(
      """{"range":""" & aRange & ""","severity":2,"code":5,"source":"nim","message":"m","tags":[1]}""",
      Diagnostic,
    )
    check diagnostic.range == rng()
    check diagnostic.severity == some 2
    check diagnostic.code.get.num == 5
    check diagnostic.source == some "nim"
    check diagnostic.message.str == "m"

  test "the range and the message are required":
    expect SerializationError:
      discard LspJson.decode("""{"message":"m"}""", Diagnostic)
    expect SerializationError:
      discard LspJson.decode("""{"range":""" & aRange & "}", Diagnostic)

suite "code action":
  test "every field is written":
    let action = CodeAction(
      command: some Command(title: "t", command: "c"), title: "a", kind: some "quickfix"
    )
    check LspJson.encode(action) ==
      """{"command":{"title":"t","command":"c"},"title":"a","kind":"quickfix"}"""

  test "only the title is required":
    check LspJson.encode(CodeAction(title: "a")) == """{"title":"a"}"""

suite "workspace edit":
  test "the changes are written by uri":
    let edit = WorkspaceEdit(
      changes: some {LspUri("file:///a.nim"): @[TextEdit(range: rng(), newText: "x")]}.toTable
    )
    check LspJson.encode(edit) ==
      """{"changes":{"file:///a.nim":[{"range":""" & aRange & ""","newText":"x"}]}}"""

  test "no changes leaves the field out":
    check LspJson.encode(WorkspaceEdit()) == "{}"

  test "apply workspace edit params write the label and the edit":
    let params = ApplyWorkspaceEditParams(label: some "rename", edit: WorkspaceEdit())
    check LspJson.encode(params) == """{"label":"rename","edit":{}}"""
    check LspJson.encode(ApplyWorkspaceEditParams()) == """{"edit":{}}"""

  test "apply workspace edit result reads applied":
    check LspJson.decode("""{"applied": true, "failureReason": "x"}""", ApplyWorkspaceEditResult).applied
    check not LspJson.decode("""{"applied": false}""", ApplyWorkspaceEditResult).applied
    expect SerializationError:
      discard LspJson.decode("{}", ApplyWorkspaceEditResult)

suite "text document params":
  test "a text document identifier reads the uri":
    check LspJson.decode("""{"uri": "file:///a.nim"}""", TextDocumentIdentifier).uri ==
      LspUri("file:///a.nim")
    expect SerializationError:
      discard LspJson.decode("{}", TextDocumentIdentifier)

  test "a text document item reads every field":
    let item = LspJson.decode(
      """{"uri": "file:///a.nim", "languageId": "nim", "version": 1, "text": "echo 1"}""",
      TextDocumentItem,
    )
    check item == TextDocumentItem(
      uri: LspUri("file:///a.nim"), languageId: "nim", version: 1, text: "echo 1"
    )

  test "a text document item requires every field":
    for json in [
      """{"languageId": "nim", "version": 1, "text": ""}""",
      """{"uri": "file:///a.nim", "version": 1, "text": ""}""",
      """{"uri": "file:///a.nim", "languageId": "nim", "text": ""}""",
      """{"uri": "file:///a.nim", "languageId": "nim", "version": 1}""",
    ]:
      checkpoint json
      expect SerializationError:
        discard LspJson.decode(json, TextDocumentItem)

  test "a text document position reads the document and the position":
    let params = LspJson.decode("{" & docPos & "}", TextDocumentPositionParams)
    check params.textDocument.uri == LspUri("file:///a.nim")
    check params.position == pos(1, 2)
    expect SerializationError:
      discard LspJson.decode("""{"textDocument": {"uri": "file:///a.nim"}}""", TextDocumentPositionParams)

  test "expand params read the level, which is optional":
    check LspJson.decode("{" & docPos & """, "level": 3}""", ExpandTextDocumentPositionParams).level ==
      some 3
    check LspJson.decode("{" & docPos & "}", ExpandTextDocumentPositionParams).level.isNone

  test "did open reads the text document":
    let params = LspJson.decode(
      """{"textDocument": {"uri": "file:///a.nim", "languageId": "nim", "version": 1, "text": "x"}}""",
      DidOpenTextDocumentParams,
    )
    check params.textDocument.text == "x"

  test "did change reads the version and the full text":
    let params = LspJson.decode(
      """{"textDocument": {"uri": "file:///a.nim", "version": 2}, "contentChanges": [{"text": "x"}]}""",
      DidChangeTextDocumentParams,
    )
    check params.textDocument.version == 2
    check params.contentChanges.mapIt(it.text) == @["x"]

  test "did change accepts an incremental change and keeps its text":
    let params = LspJson.decode(
      """{"textDocument": {"uri": "file:///a.nim", "version": 2}, "contentChanges": [{"range": """ &
        aRange & """, "rangeLength": 1, "text": "x"}]}""",
      DidChangeTextDocumentParams,
    )
    check params.contentChanges.mapIt(it.text) == @["x"]

  test "a content change requires the text":
    expect SerializationError:
      discard LspJson.decode("{}", TextDocumentContentChangeEvent)

  test "will save reads the reason":
    let params = LspJson.decode(
      """{"textDocument": {"uri": "file:///a.nim"}, "reason": 1}""", WillSaveTextDocumentParams
    )
    check params.reason == 1
    expect SerializationError:
      discard LspJson.decode("""{"textDocument": {"uri": "file:///a.nim"}}""", WillSaveTextDocumentParams)

  test "did save reads the text, which is optional":
    check LspJson.decode(
      """{"textDocument": {"uri": "file:///a.nim"}, "text": "x"}""", DidSaveTextDocumentParams
    ).text == some "x"
    check LspJson.decode(
      """{"textDocument": {"uri": "file:///a.nim"}}""", DidSaveTextDocumentParams
    ).text.isNone

  test "did close reads the text document":
    check LspJson.decode(
      """{"textDocument": {"uri": "file:///a.nim"}}""", DidCloseTextDocumentParams
    ).textDocument.uri == LspUri("file:///a.nim")
    expect SerializationError:
      discard LspJson.decode("{}", DidCloseTextDocumentParams)

suite "request params":
  test "set trace reads the value":
    check LspJson.decode("""{"value": "off"}""", SetTraceParams).value == "off"
    expect SerializationError:
      discard LspJson.decode("{}", SetTraceParams)

  test "workspace symbol reads the query":
    let params = LspJson.decode(
      """{"query": "foo", "workDoneToken": 1, "partialResultToken": "p"}""", WorkspaceSymbolParams
    )
    check params.query == "foo"
    expect SerializationError:
      discard LspJson.decode("{}", WorkspaceSymbolParams)

  test "completion reads the context, which is optional":
    let params = LspJson.decode(
      "{" & docPos & """, "context": {"triggerKind": 2, "triggerCharacter": "."}}""",
      CompletionParams,
    )
    check params.position == pos(1, 2)
    check params.context.get.triggerKind == 2
    check LspJson.decode("{" & docPos & "}", CompletionParams).context.isNone

  test "a completion context requires the trigger kind":
    expect SerializationError:
      discard LspJson.decode("{}", CompletionContext)

  test "hover reads the document and the position":
    let params = LspJson.decode("{" & docPos & "}", HoverParams)
    check params.textDocument.uri == LspUri("file:///a.nim")
    check params.position == pos(1, 2)

  test "references require the context":
    expect SerializationError:
      discard LspJson.decode("{" & docPos & "}", ReferenceParams)
    expect SerializationError:
      discard LspJson.decode("{" & docPos & """, "context": {}}""", ReferenceParams)

  test "document symbol reads the text document":
    check LspJson.decode(
      """{"textDocument": {"uri": "file:///a.nim"}}""", DocumentSymbolParams
    ).textDocument.uri == LspUri("file:///a.nim")
    expect SerializationError:
      discard LspJson.decode("{}", DocumentSymbolParams)

  test "code action reads the range and the diagnostics":
    let params = LspJson.decode(
      """{"textDocument": {"uri": "file:///a.nim"}, "range": """ & aRange &
        """, "context": {"diagnostics": [{"range": """ & zeroRange &
        """, "message": "m"}], "only": ["quickfix"]}}""",
      CodeActionParams,
    )
    check params.range == rng()
    check params.context.diagnostics.mapIt(it.message.str) == @["m"]

  test "code action requires the range and the context":
    expect SerializationError:
      discard LspJson.decode(
        """{"textDocument": {"uri": "file:///a.nim"}, "context": {"diagnostics": []}}""",
        CodeActionParams,
      )
    expect SerializationError:
      discard LspJson.decode(
        """{"textDocument": {"uri": "file:///a.nim"}, "range": """ & aRange & "}",
        CodeActionParams,
      )
    expect SerializationError:
      discard LspJson.decode("{}", CodeActionContext)

  test "rename reads the new name":
    check LspJson.decode("{" & docPos & """, "newName": "b"}""", RenameParams).newName == "b"
    expect SerializationError:
      discard LspJson.decode("{" & docPos & "}", RenameParams)

  test "prepare rename reads the document and the position":
    check LspJson.decode("{" & docPos & "}", PrepareRenameParams).position == pos(1, 2)
    expect SerializationError:
      discard LspJson.decode("""{"textDocument": {"uri": "file:///a.nim"}}""", PrepareRenameParams)

  test "signature help reads the context, which is optional":
    let params = LspJson.decode(
      "{" & docPos &
        """, "context": {"triggerKind": 2, "isRetrigger": true, "activeSignatureHelp": {"signatures": [{"label": "f(a)", "parameters": [{"label": "a"}]}], "activeSignature": 0}}}""",
      SignatureHelpParams,
    )
    let context = params.context.get
    check context.triggerKind == 2
    check context.isRetrigger
    check context.activeSignatureHelp.get.signatures[0].label == "f(a)"
    check context.activeSignatureHelp.get.signatures[0].parameters.get[0].label.str == "a"
    check LspJson.decode("{" & docPos & "}", SignatureHelpParams).context.isNone

  test "a signature help context requires the trigger kind and the retrigger flag":
    expect SerializationError:
      discard LspJson.decode("""{"isRetrigger": false}""", SignatureHelpContext)
    expect SerializationError:
      discard LspJson.decode("""{"triggerKind": 1}""", SignatureHelpContext)

  test "inlay hint reads the text document and the range":
    let params = LspJson.decode(
      """{"textDocument": {"uri": "file:///a.nim"}, "range": """ & aRange & "}", InlayHintParams
    )
    check params.range == rng()
    expect SerializationError:
      discard LspJson.decode("""{"textDocument": {"uri": "file:///a.nim"}}""", InlayHintParams)

suite "workspace notifications":
  test "did change watched files reads the changes":
    let params = LspJson.decode(
      """{"changes": [{"uri": "file:///a.nim", "type": 2}]}""", DidChangeWatchedFilesParams
    )
    check params.changes == @[FileEvent(uri: LspUri("file:///a.nim"), `type`: 2)]

  test "a file event requires the uri and the type":
    expect SerializationError:
      discard LspJson.decode("""{"uri": "file:///a.nim"}""", FileEvent)
    expect SerializationError:
      discard LspJson.decode("""{"type": 1}""", FileEvent)

  test "did change workspace folders reads the added and the removed folders":
    let params = LspJson.decode(
      """{"event": {"added": [{"uri": "file:///a", "name": "a"}], "removed": [{"uri": "file:///b", "name": "b"}]}}""",
      DidChangeWorkspaceFoldersParams,
    )
    check params.event.added == @[WorkspaceFolder(uri: LspUri("file:///a"), name: "a")]
    check params.event.removed == @[WorkspaceFolder(uri: LspUri("file:///b"), name: "b")]

  test "a workspace folders change requires the added and the removed folders":
    expect SerializationError:
      discard LspJson.decode("""{"added": []}""", WorkspaceFoldersChangeEvent)
    expect SerializationError:
      discard LspJson.decode("""{"removed": []}""", WorkspaceFoldersChangeEvent)

  test "a workspace folder is read and written":
    let folder = WorkspaceFolder(uri: LspUri("file:///a"), name: "a")
    check LspJson.encode(folder) == """{"uri":"file:///a","name":"a"}"""
    check LspJson.decode("""{"uri":"file:///a","name":"a"}""", WorkspaceFolder) == folder
    expect SerializationError:
      discard LspJson.decode("""{"uri":"file:///a"}""", WorkspaceFolder)

  test "initialize reads the workspace folders":
    let params = LspJson.decode(
      """{"processId": 1, "rootPath": "/a", "capabilities": {}, "workspaceFolders": [{"uri": "file:///a", "name": "a"}]}""",
      InitializeParams,
    )
    check params.rootPath == some "/a"
    check params.workspaceFolders.get == @[WorkspaceFolder(uri: LspUri("file:///a"), name: "a")]

suite "client capabilities":
  test "every field is read":
    let caps = LspJson.decode(
      """{
        "workspace": {
          "didChangeConfiguration": {"dynamicRegistration": true},
          "didChangeWatchedFiles": {"dynamicRegistration": true},
          "executeCommand": {"dynamicRegistration": true},
          "workspaceFolders": true,
          "configuration": true,
          "inlayHint": {"refreshSupport": true},
          "diagnostics": {"refreshSupport": true}
        },
        "textDocument": {
          "completion": {"dynamicRegistration": true, "contextSupport": true},
          "hover": {"dynamicRegistration": true},
          "signatureHelp": {"dynamicRegistration": true, "contextSupport": true},
          "declaration": {"dynamicRegistration": true},
          "definition": {"dynamicRegistration": true},
          "typeDefinition": {"dynamicRegistration": true},
          "references": {"dynamicRegistration": true},
          "documentHighlight": {"dynamicRegistration": true},
          "codeAction": {"dynamicRegistration": true},
          "formatting": {"dynamicRegistration": true},
          "rename": {"dynamicRegistration": true, "prepareSupport": true},
          "inlayHint": {"dynamicRegistration": true}
        },
        "window": {"workDoneProgress": true},
        "general": {"positionEncodings": ["utf-16"]}
      }""",
      ClientCapabilities,
    )
    let ws = caps.workspace.get
    check ws.didChangeConfiguration.get.dynamicRegistration == some true
    check ws.didChangeWatchedFiles.get.dynamicRegistration == some true
    check ws.executeCommand.get.dynamicRegistration == some true
    check ws.workspaceFolders == some true
    check ws.configuration == some true
    check ws.inlayHint.get.refreshSupport == some true
    check ws.diagnostics.get.refreshSupport == some true
    let td = caps.textDocument.get
    check td.completion.get.dynamicRegistration == some true
    check td.completion.get.contextSupport == some true
    check td.hover.get.dynamicRegistration == some true
    check td.signatureHelp.get.dynamicRegistration == some true
    check td.signatureHelp.get.contextSupport == some true
    check td.declaration.get.dynamicRegistration == some true
    check td.definition.get.dynamicRegistration == some true
    check td.typeDefinition.get.dynamicRegistration == some true
    check td.references.get.dynamicRegistration == some true
    check td.documentHighlight.get.dynamicRegistration == some true
    check td.codeAction.get.dynamicRegistration == some true
    check td.formatting.get.dynamicRegistration == some true
    check td.rename.get.dynamicRegistration == some true
    check td.rename.get.prepareSupport == some true
    check td.inlayHint.get.dynamicRegistration == some true
    check caps.window.get.workDoneProgress == some true

  test "an empty object reads every field as none":
    let caps = LspJson.decode("{}", ClientCapabilities)
    check caps.workspace.isNone
    check caps.textDocument.isNone
    check caps.window.isNone

suite "server capabilities options":
  test "every field is written":
    let caps = ServerCapabilities(
      textDocumentSync:
        some ServerCapabilitiesTextDocumentSync(kind: stdsKind, syncKind: 1),
      completionProvider: some CompletionOptions(
        workDoneProgress: some false,
        resolveProvider: some false,
        triggerCharacters: some @["."],
      ),
      hoverProvider: some true,
      signatureHelpProvider:
        some SignatureHelpOptions(triggerCharacters: some @["(", ","]),
      declarationProvider: some true,
      definitionProvider: some true,
      typeDefinitionProvider: some true,
      referencesProvider: some true,
      documentHighlightProvider: some true,
      documentSymbolProvider: some true,
      workspaceSymbolProvider: some true,
      codeActionProvider: some true,
      documentFormattingProvider: some false,
      renameProvider: some ServerCapabilitiesRenameProvider(kind: srpBool, boolean: true),
      executeCommandProvider: some ExecuteCommandOptions(commands: @["c"]),
      inlayHintProvider:
        some ServerCapabilitiesInlayHintProvider(kind: sihpBool, boolean: true),
      workspace: some WorkspaceOptions(
        workspaceFolders: some WorkspaceFoldersServerCapabilities(supported: some true)
      ),
    )
    check LspJson.encode(caps) ==
      """{"textDocumentSync":1,"completionProvider":{"workDoneProgress":false,"resolveProvider":false,"triggerCharacters":["."]},"hoverProvider":true,"signatureHelpProvider":{"triggerCharacters":["(",","]},"declarationProvider":true,"definitionProvider":true,"typeDefinitionProvider":true,"referencesProvider":true,"documentHighlightProvider":true,"documentSymbolProvider":true,"workspaceSymbolProvider":true,"codeActionProvider":true,"documentFormattingProvider":false,"renameProvider":true,"executeCommandProvider":{"commands":["c"]},"inlayHintProvider":true,"workspace":{"workspaceFolders":{"supported":true}}}"""

  test "no fields writes an empty object":
    check LspJson.encode(ServerCapabilities()) == "{}"
    check LspJson.encode(InitializeResult()) == """{"capabilities":{}}"""

  test "execute command options require the commands":
    check LspJson.encode(ExecuteCommandOptions()) == """{"commands":[]}"""

  test "the inlay hint provider is written as its options":
    let caps = ServerCapabilities(
      inlayHintProvider: some ServerCapabilitiesInlayHintProvider(
        kind: sihpOptions, options: InlayHintOptions(resolveProvider: some false)
      )
    )
    check LspJson.encode(caps) == """{"inlayHintProvider":{"resolveProvider":false}}"""

  test "every text document sync option is written":
    let options = TextDocumentSyncOptions(
      openClose: some true,
      change: some 1,
      willSave: some false,
      willSaveWaitUntil: some true,
      save: some TextDocumentSyncOptionsSave(kind: tdsosOptions, options: SaveOptions()),
    )
    check LspJson.encode(options) ==
      """{"openClose":true,"change":1,"willSave":false,"willSaveWaitUntil":true,"save":{}}"""

suite "server requests and notifications":
  test "show message writes the type and the message":
    check LspJson.encode(ShowMessageParams(`type`: 3, message: "m")) ==
      """{"type":3,"message":"m"}"""

  test "registration params write the registrations":
    let params = RegistrationParams(registrations: @[Registration(id: "i", `method`: "m")])
    check LspJson.encode(params) == """{"registrations":[{"id":"i","method":"m"}]}"""

  test "configuration params write the items":
    let params =
      ConfigurationParams(items: @[ConfigurationItem(section: some "nim"), ConfigurationItem()])
    check LspJson.encode(params) == """{"items":[{"section":"nim"},{}]}"""

  test "publish diagnostics writes the uri and the diagnostics":
    let params = PublishDiagnosticsParams(
      uri: LspUri("file:///a.nim"),
      diagnostics: @[Diagnostic(message: DiagnosticMessage(kind: dmStr, str: "m"))],
    )
    check LspJson.encode(params) ==
      """{"uri":"file:///a.nim","diagnostics":[{"range":""" & zeroRange &
        ""","message":"m"}]}"""

  test "no diagnostics writes an empty list":
    let params = PublishDiagnosticsParams(uri: LspUri("file:///a.nim"))
    check LspJson.encode(params) == """{"uri":"file:///a.nim","diagnostics":[]}"""

  test "a work done progress begin writes the message":
    let begin = WorkDoneProgressBegin(kind: "begin", title: "t", message: some "m")
    check LspJson.encode(begin) == """{"kind":"begin","title":"t","message":"m"}"""
    let done = WorkDoneProgressEnd(kind: "end", message: some "m")
    check LspJson.encode(done) == """{"kind":"end","message":"m"}"""

suite "responses":
  test "a completion item writes every field":
    let item = CompletionItem(
      label: "echo",
      kind: some 3,
      detail: some "proc ()",
      documentation: some CompletionItemDocumentation(kind: cidStr, str: "d"),
      command: some Command(title: "t", command: "c"),
      data: some JsonString("1"),
    )
    check LspJson.encode(item) ==
      """{"label":"echo","kind":3,"detail":"proc ()","documentation":"d","command":{"title":"t","command":"c"},"data":1}"""

  test "a document highlight writes the range and the kind":
    check LspJson.encode(DocumentHighlight(range: rng(), kind: some 1)) ==
      """{"range":""" & aRange & ""","kind":1}"""
    check LspJson.encode(DocumentHighlight(range: rng())) == """{"range":""" & aRange & "}"

  test "a symbol information writes the name, the kind and the location":
    let symbol = SymbolInformation(
      name: "f", kind: 12, location: Location(uri: LspUri("file:///a.nim"), range: rng())
    )
    check LspJson.encode(symbol) ==
      """{"name":"f","kind":12,"location":{"uri":"file:///a.nim","range":""" & aRange &
        "}}"

  test "an expand result writes the range and the content":
    check LspJson.encode(ExpandResult(range: rng(), content: "c")) ==
      """{"range":""" & aRange & ""","content":"c"}"""

  test "a signature help writes every field":
    let help = SignatureHelp(
      signatures: @[
        SignatureInformation(
          label: "f(a)",
          parameters: some @[
            ParameterInformation(label: ParameterInformationLabel(kind: pilStr, str: "a"))
          ],
        )
      ],
      activeSignature: some uinteger(0),
      activeParameter: some uinteger(1),
    )
    let json =
      """{"signatures":[{"label":"f(a)","parameters":[{"label":"a"}]}],"activeSignature":0,"activeParameter":1}"""
    check LspJson.encode(help) == json
    let decoded = LspJson.decode(json, SignatureHelp)
    check decoded.signatures[0].label == "f(a)"
    check decoded.activeParameter.get.int == 1

  test "a signature help requires the signatures":
    expect SerializationError:
      discard LspJson.decode("{}", SignatureHelp)
    expect SerializationError:
      discard LspJson.decode("{}", SignatureInformation)
    expect SerializationError:
      discard LspJson.decode("{}", ParameterInformation)

  test "an inlay hint writes every field":
    let hint = InlayHint(
      position: pos(1, 2),
      label: InlayHintLabel(kind: ihlStr, str: ": int"),
      kind: some 1,
      textEdits: some @[TextEdit(range: rng(), newText: ": int")],
      tooltip: some InlayHintTooltip(kind: ihtStr, str: "t"),
      paddingLeft: some true,
      paddingRight: some false,
    )
    check LspJson.encode(hint) ==
      """{"position":{"line":1,"character":2},"label":": int","kind":1,"textEdits":[{"range":""" &
        aRange & ""","newText":": int"}],"tooltip":"t","paddingLeft":true,"paddingRight":false}"""

  test "an inlay hint label part writes its location and command":
    let part = InlayHintLabelPart(
      value: "v",
      location: some Location(uri: LspUri("file:///a.nim"), range: rng()),
      command: some Command(title: "t", command: "c"),
    )
    check LspJson.encode(part) ==
      """{"value":"v","location":{"uri":"file:///a.nim","range":""" & aRange &
        """},"command":{"title":"t","command":"c"}}"""

suite "nim extensions":
  test "the status and capabilities params are empty objects":
    discard LspJson.decode("{}", NimLangServerStatusParams)
    discard LspJson.decode("{}", NimLangServerCapabilitiesParams)

  test "suggest params read the action and the project file":
    let params = LspJson.decode(
      """{"action": "restartAll", "projectFile": "/a.nim"}""", SuggestParams
    )
    check params.action == saRestartAll
    check params.projectFile == "/a.nim"

  test "suggest params reject an unknown action":
    expect SerializationError:
      discard LspJson.decode("""{"action": "x", "projectFile": "/a.nim"}""", SuggestParams)

  test "a suggest result writes the action":
    check LspJson.encode(SuggestResult(actionPerformed: saRestart)) ==
      """{"actionPerformed":"restart"}"""

  test "the status writes every field":
    let status = NimLangServerStatus(
      lspPath: "/nls",
      version: "1",
      nimsuggestInstances: @[
        NimsuggestStatus(
          projectFile: "/a.nim",
          capabilities: @[nsCon, nsOutline2],
          version: "2",
          path: "/ns",
          port: 5,
          openFiles: @["/a.nim"],
          unknownFiles: @["/b.nim"],
        )
      ],
      openFiles: @["/a.nim"],
      extensionCapabilities: @[excRestartSuggest],
      pendingRequests: @[
        PendingRequestStatus(name: "n", projectFile: "/a.nim", time: "t", state: "s")
      ],
      projectErrors:
        @[ProjectError(projectFile: "/a.nim", errorMessage: "e", lastKnownCmd: "c")],
    )
    check LspJson.encode(status) ==
      """{"lspPath":"/nls","version":"1","nimsuggestInstances":[{"projectFile":"/a.nim","capabilities":["con","outline2"],"version":"2","path":"/ns","port":5,"openFiles":["/a.nim"],"unknownFiles":["/b.nim"]}],"openFiles":["/a.nim"],"extensionCapabilities":["RestartSuggest"],"pendingRequests":[{"name":"n","projectFile":"/a.nim","time":"t","state":"s"}],"projectErrors":[{"projectFile":"/a.nim","errorMessage":"e","lastKnownCmd":"c"}]}"""

  test "a nimble task writes the name and the description":
    check LspJson.encode(NimbleTask(name: "test", description: "d")) ==
      """{"name":"test","description":"d"}"""

  test "run task reads the command and writes the output":
    check LspJson.decode("""{"command": ["nimble", "test"]}""", RunTaskParams).command ==
      @["nimble", "test"]
    expect SerializationError:
      discard LspJson.decode("{}", RunTaskParams)
    check LspJson.encode(RunTaskResult(command: @["nimble"], output: @["ok"])) ==
      """{"command":["nimble"],"output":["ok"]}"""

  test "list tests reads the entry point and writes the project info":
    check LspJson.decode("""{"entryPoint": "/t.nim"}""", ListTestsParams).entryPoint ==
      "/t.nim"
    expect SerializationError:
      discard LspJson.decode("{}", ListTestsParams)
    let res = ListTestsResult(
      projectInfo: TestProjectInfo(
        entryPoint: "/t.nim",
        suites: {
          "s": TestSuiteInfo(name: "s", tests: @[TestInfo(name: "t", line: 3, file: "/t.nim")])
        }.toTable,
        error: some "e",
      )
    )
    check LspJson.encode(res) ==
      """{"projectInfo":{"entryPoint":"/t.nim","suites":{"s":{"name":"s","tests":[{"name":"t","line":3,"file":"/t.nim"}]}},"error":"e"}}"""

  test "run test reads the suite and the test names, which are optional":
    let params = LspJson.decode(
      """{"entryPoint": "/t.nim", "suiteName": "s", "testNames": ["a"]}""", RunTestParams
    )
    check params.suiteName == some "s"
    check params.testNames == some @["a"]
    let bare = LspJson.decode("""{"entryPoint": "/t.nim"}""", RunTestParams)
    check bare.suiteName.isNone and bare.testNames.isNone
    expect SerializationError:
      discard LspJson.decode("{}", RunTestParams)

  test "a run test result writes every field":
    let res = RunTestProjectResult(
      suites: @[
        RunTestSuiteResult(
          name: "s",
          tests: 2,
          failures: 1,
          errors: 0,
          skipped: 0,
          time: 1.5,
          testResults: @[
            RunTestResult(name: "a", time: 0.5),
            RunTestResult(name: "b", time: 1.0, failure: some "f"),
          ],
        )
      ],
      fullOutput: "o",
    )
    check LspJson.encode(res) ==
      """{"suites":[{"name":"s","tests":2,"failures":1,"errors":0,"skipped":0,"time":1.5,"testResults":[{"name":"a","time":0.5},{"name":"b","time":1.0,"failure":"f"}]}],"fullOutput":"o"}"""

  test "a cancel test result writes cancelled":
    check LspJson.encode(CancelTestResult(cancelled: true)) == """{"cancelled":true}"""

suite "mcp":
  test "the notification and the paginated request params accept unknown fields":
    discard LspJson.decode("""{"_meta": {}}""", McpNotificationParams)
    discard LspJson.decode("""{"cursor": "c"}""", McpPaginatedRequestParams)

  test "the call tool params require the name":
    expect SerializationError:
      discard LspJson.decode("""{"arguments": {}}""", McpCallToolRequestParams)

  test "an implementation writes the title and the description":
    let impl = McpImplementation(name: "n", title: some "N", version: "1", description: some "d")
    check LspJson.encode(impl) == """{"name":"n","title":"N","version":"1","description":"d"}"""

  test "the tool list writes the tools with their schemas":
    let res = McpListToolsResult(
      tools: @[
        McpTool(
          name: "t",
          inputSchema: McpToolSchema(
            `type`: "object",
            properties: some {"path": JsonString("""{"type":"string"}""")}.toOrderedTable,
            required: some @["path"],
          ),
          outputSchema: some McpToolSchema(`type`: "object"),
        )
      ]
    )
    check LspJson.encode(res) ==
      """{"tools":[{"name":"t","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]},"outputSchema":{"type":"object"}}]}"""

  test "no server capabilities writes an empty object":
    check LspJson.encode(McpServerCapabilities()) == "{}"
