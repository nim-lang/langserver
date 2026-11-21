import unittest2, ../protocol/types

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
