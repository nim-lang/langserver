import std/sequtils, unittest2, ../protocol/[oneof, types]

type SelectorHolder = object
  documentSelector: TextDocumentRegistrationOptionsDocumentSelector

LspJson.useDefaultReaderFor(DocumentFilter)
LspJson.useOneOfReaderFor(TextDocumentRegistrationOptionsDocumentSelector)
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

suite "mcp tool call params":
  test "the arguments are kept as json, without whitespace":
    let params = LspJson.decode(
      """{"name": "nimFindReferences", "arguments": {"path": "/a/hw.nim", "line": 3}}""",
      McpCallToolParams,
    )
    check params.arguments.get.string == """{"path":"/a/hw.nim","line":3}"""

  test "no arguments decodes as none":
    let params = LspJson.decode("""{"name": "nimCheckProject"}""", McpCallToolParams)
    check params.arguments.isNone

suite "initialize params":
  test "the initialization options are kept as json":
    let params = LspJson.decode(
      """{"processId": 1, "capabilities": {}, "initializationOptions": {"a": [1]}}""",
      LspInitializeParams,
    )
    check params.initializationOptions.get.string == """{"a":[1]}"""

  test "null initialization options decode as none":
    let params = LspJson.decode(
      """{"processId": null, "capabilities": {}, "initializationOptions": null}""",
      LspInitializeParams,
    )
    check params.initializationOptions.isNone
    check params.processId.isNone

suite "did change configuration params":
  test "the settings are kept as json, without whitespace":
    let params = LspJson.decode(
      """{"settings": {"nim": {"projectMapping": []}}}""", DidChangeConfigurationParams
    )
    check params.settings.get.string == """{"nim":{"projectMapping":[]}}"""

  test "null settings decode as none":
    let params = LspJson.decode("""{"settings": null}""", DidChangeConfigurationParams)
    check params.settings.isNone

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

suite "initialized params":
  test "an empty object is accepted":
    check not LspJson.decode("{}", InitializedParams).isNil

  test "something that is not an object is rejected":
    expect SerializationError:
      discard LspJson.decode("[]", InitializedParams)

suite "work done progress":
  test "a begin carries its kind and title":
    let params = ProgressParams[WorkDoneProgressBegin](
      token: "t",
      value: WorkDoneProgressBegin(
        kind: "begin", title: "Checking", percentage: some uinteger(5)
      ),
    )
    check LspJson.encode(params) ==
      """{"token":"t","value":{"kind":"begin","title":"Checking","percentage":5}}"""

  test "a report leaves out what is not set":
    let params = ProgressParams[WorkDoneProgressReport](
      token: "t", value: WorkDoneProgressReport(kind: "report", message: some "half")
    )
    check LspJson.encode(params) ==
      """{"token":"t","value":{"kind":"report","message":"half"}}"""

  test "an end has no title":
    let params = ProgressParams[WorkDoneProgressEnd](
      token: "t", value: WorkDoneProgressEnd(kind: "end")
    )
    check LspJson.encode(params) == """{"token":"t","value":{"kind":"end"}}"""

  test "creating a progress sends only the token":
    check LspJson.encode(WorkDoneProgressCreateParams(token: "t")) == """{"token":"t"}"""

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
      """{"experimental": {"snippetTextEdit": true}}""", LspClientCapabilities
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

suite "mcp tool call result":
  test "the structured content is written as it is":
    let res = McpCallToolResult(
      content: @[McpContentBlock(`type`: TextContent, text: """{"refs":[]}""")],
      structuredContent: some JsonString("""{"refs":[]}"""),
    )
    check LspJson.encode(res) ==
      """{"content":[{"type":"text","text":"{\"refs\":[]}"}],"structuredContent":{"refs":[]},"isError":false}"""

  test "no structured content leaves the field out":
    let res = McpCallToolResult(
      content: @[McpContentBlock(`type`: TextContent, text: "x")], isError: true
    )
    check LspJson.encode(res) ==
      """{"content":[{"type":"text","text":"x"}],"isError":true}"""

suite "server capabilities":
  test "text document sync is written as its options or its kind":
    let options = LspServerCapabilities(
      textDocumentSync: some ServerCapabilitiesTextDocumentSync(
        kind: stdsOptions,
        options: TextDocumentSyncOptions(openClose: some true, change: some 1),
      )
    )
    check LspJson.encode(options) ==
      """{"textDocumentSync":{"openClose":true,"change":1}}"""
    let kind = LspServerCapabilities(
      textDocumentSync:
        some ServerCapabilitiesTextDocumentSync(kind: stdsKind, syncKind: 2)
    )
    check LspJson.encode(kind) == """{"textDocumentSync":2}"""

  test "rename is written as a boolean or its options":
    let boolean = LspServerCapabilities(
      renameProvider: some ServerCapabilitiesRenameProvider(kind: srpBool, boolean: true)
    )
    check LspJson.encode(boolean) == """{"renameProvider":true}"""
    let options = LspServerCapabilities(
      renameProvider: some ServerCapabilitiesRenameProvider(
        kind: srpOptions, options: RenameOptions(prepareProvider: some true)
      )
    )
    check LspJson.encode(options) == """{"renameProvider":{"prepareProvider":true}}"""

  test "a registration option writes the document selector it inherits":
    let capabilities = LspServerCapabilities(
      implementationProvider: some ServerCapabilitiesImplementationProvider(
        kind: sipRegistration,
        registration: ImplementationRegistrationOptions(
          documentSelector: TextDocumentRegistrationOptionsDocumentSelector(
            kind: tdrdsSelector, selector: @[DocumentFilter(language: some "nim")]
          ),
          id: some "impl",
        ),
      ),
      colorProvider: some ServerCapabilitiesColorProvider(kind: scpBool, boolean: false),
    )
    check LspJson.encode(capabilities) ==
      """{"implementationProvider":{"id":"impl","documentSelector":[{"language":"nim"}]},"colorProvider":false}"""

  test "the experimental capabilities are written as they are":
    let capabilities =
      LspServerCapabilities(experimental: some JsonString("""{"x":1}"""))
    check LspJson.encode(capabilities) == """{"experimental":{"x":1}}"""

suite "document selector":
  test "a registration without a document selector writes null":
    let options = ImplementationRegistrationOptions(id: some "impl")
    check LspJson.encode(options) == """{"id":"impl","documentSelector":null}"""

  test "a document selector is written as its filters":
    let holder = SelectorHolder(
      documentSelector: TextDocumentRegistrationOptionsDocumentSelector(
        kind: tdrdsSelector, selector: @[DocumentFilter(scheme: some "file")]
      )
    )
    check LspJson.encode(holder) == """{"documentSelector":[{"scheme":"file"}]}"""

  test "null is read as the null member":
    let holder = LspJson.decode("""{"documentSelector": null}""", SelectorHolder)
    check holder.documentSelector.kind == tdrdsNull

  test "filters are read as the selector member":
    let holder =
      LspJson.decode("""{"documentSelector": [{"language": "nim"}]}""", SelectorHolder)
    check holder.documentSelector.kind == tdrdsSelector
    check holder.documentSelector.selector[0].language == some "nim"

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
      watchers: some @[FileSystemWatcher(globPattern: "**/*.nim", kind: some 7)]
    )
    check LspJson.encode(options) ==
      """{"watchers":[{"globPattern":"**/*.nim","kind":7}]}"""
