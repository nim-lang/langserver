import
  std/[json, options, os, sequtils, strutils],
  chronos,
  json_rpc/errors,
  unittest2,
  ../[nimlangserver, ls, utils],
  ../protocol/types,
  ../routes/mcp,
  ./lspsocketclient

proc toolArguments(node: JsonNode): Option[JsonString] =
  some JsonString($node)

type McpSocketClient = ref object
  transport: StreamTransport
  nextId: int

proc initMcpServer(
    mainFile: string, notifications = new seq[string]
): Future[(LanguageServer, McpInitializeResult)] {.async: (raises: [CatchableError]).} =
  let
    cmdParams = CommandLineParams(mode: some ServerMode.mcp)
    initParams = McpInitializeRequestParams(
      protocolVersion: McpProtocolVersion,
      capabilities: McpClientCapabilities(),
      clientInfo: McpImplementation(name: "nimble test", version: "1"),
    )
    ls = initLs(cmdParams, ensureStorageDir())

  ls.notifyAction = proc(name: string, params: JsonString) {.async: (raises: []).} =
    notifications[].add name
  ls.callAction = proc(
      name: string, params: JsonString
  ): Future[JsonString] {.async: (raises: [CancelledError, JsonRpcError]).} =
    JsonString("null")
  ls.onExit = proc(): Future[void] {.async: (raises: []).} =
    discard

  let initRes = await mcp.initialize((ls: ls, onExit: ls.onExit), initParams)

  (ls, initRes)

proc checkToolResult(res: McpCallToolResult) =
  check not res.isError.get(false)
  check res.structuredContent.isSome
  if res.structuredContent.isSome:
    check parseJson(res.content[0].text) == res.structuredContent.get.string.parseJson

proc newMcpSocketClient(port: Port): Future[McpSocketClient] {.async.} =
  let addresses = resolveTAddress("localhost", port)
  McpSocketClient(transport: await connect(addresses[0]))

proc close(client: McpSocketClient): Future[void] {.async.} =
  if not client.transport.isNil:
    await client.transport.closeWait()

proc callRpc(
    client: McpSocketClient, name: string, params: JsonNode
): Future[JsonNode] {.async.} =
  inc client.nextId
  let id = client.nextId
  let reqJson = %*{"jsonrpc": "2.0", "id": id, "method": name, "params": params}
  discard await client.transport.write($reqJson & "\n")

  while true:
    let response = await client.transport.readLine(sep = "\n")
    if response == "":
      raise newException(IOError, "MCP server disconnected")

    let responseJson = parseJson(response)
    if "id" in responseJson and responseJson["id"].getInt() == id:
      if "error" in responseJson:
        raise newException(JsonRpcError, $responseJson["error"])
      return responseJson["result"]

suite "MCP routes":
  let
    mainFile = absolutePath("nimlangserver.nim")
    (ls, initRes) = waitFor initMcpServer(mainFile)

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "initialize returns MCP info":
    check initRes.protocolVersion == McpProtocolVersion
    check initRes.serverInfo.name == "nimlangserver"
    check initRes.serverInfo.version == LSPVersion

  test "tools/call error results do not crash the server":
    # nimCheckProject without a uri takes its error path, whose result used to
    # carry a nil structuredContent that segfaulted the server while serialising
    # the response.
    let
      emptyDir = getTempDir() / "nimlangserver-mcp-no-project"
      savedDir = os.getCurrentDir()
    createDir(emptyDir)
    setCurrentDir(emptyDir)
    defer:
      setCurrentDir(savedDir)

    let
      rpcCmdParams = CommandLineParams(
        mode: some ServerMode.mcp,
        transport: some TransportMode.socket,
        port: getNextFreePort(),
      )
      rpcLs = main(rpcCmdParams)
      rpcClient = waitFor newMcpSocketClient(rpcCmdParams.port)

    defer:
      waitFor rpcClient.close()
      waitFor rpcLs.onExit()

    discard waitFor rpcClient.callRpc(
      "initialize",
      %*{
        "protocolVersion": McpProtocolVersion,
        "capabilities": {},
        "clientInfo": {"name": "nimlangserver tests", "version": "1"},
      },
    )

    let checkProject = waitFor rpcClient.callRpc(
      "tools/call", %*{"name": "nimCheckProject", "arguments": {}}
    )
    check checkProject{"isError"}.getBool(false)
    check checkProject{"content"}[0]{"text"}.getStr.startsWith("Invalid arguments: ")
    check "structuredContent" notin checkProject

    let httpSymbols = waitFor rpcClient.callRpc(
      "tools/call",
      %*{
        "name": "nimFindSymbols",
        "arguments": {"uri": "https://example.com/a.nim", "query": "add"},
      },
    )
    check httpSymbols{"isError"}.getBool(false)
    check httpSymbols{"content"}[0]{"text"}.getStr == "Argument uri must be a file URI"

    let nimbleFile = savedDir / "nimlangserver.nimble"
    check fileExists(nimbleFile)
    let nimbleProject = waitFor rpcClient.callRpc(
      "tools/call",
      %*{"name": "nimCheckProject", "arguments": {"uri": nimbleFile.Path.pathToUri}},
    )
    check nimbleProject{"isError"}.getBool(false)
    check nimbleProject{"content"}[0]{"text"}.getStr ==
      "Argument uri must be a .nim file"

    let missingFile = savedDir / "doesnotexist.nim"
    check not fileExists(missingFile)
    let missingSymbols = waitFor rpcClient.callRpc(
      "tools/call",
      %*{
        "name": "nimFindSymbols",
        "arguments": {"uri": missingFile.Path.pathToUri, "query": "add"},
      },
    )
    check missingSymbols{"isError"}.getBool(false)
    check missingSymbols{"content"}[0]{"text"}.getStr ==
      "Argument uri must be an existing .nim file"

    let badLine = waitFor rpcClient.callRpc(
      "tools/call",
      %*{
        "name": "nimFindReferences",
        "arguments": {"path": "a.nim", "line": "x", "column": 1},
      },
    )
    check badLine{"isError"}.getBool(false)
    check badLine{"content"}[0]{"text"}.getStr.startsWith("Invalid arguments: ")

    #An unknown tool is a protocol error, not a tool result
    try:
      discard waitFor rpcClient.callRpc(
        "tools/call", %*{"name": "thisToolDoesNotExist", "arguments": {}}
      )
      checkpoint "an unknown tool was answered with a result"
      fail()
    except JsonRpcError as err:
      check "-32602" in err.msg
      check "Unknown tool: thisToolDoesNotExist" in err.msg

  test "tools/call is refused until initialize":
    let
      emptyDir = getTempDir() / "nimlangserver-mcp-no-project"
      savedDir = os.getCurrentDir()
    createDir(emptyDir)
    setCurrentDir(emptyDir)
    defer:
      setCurrentDir(savedDir)

    let
      rpcCmdParams = CommandLineParams(
        mode: some ServerMode.mcp,
        transport: some TransportMode.socket,
        port: getNextFreePort(),
      )
      rpcLs = main(rpcCmdParams)
      rpcClient = waitFor newMcpSocketClient(rpcCmdParams.port)

    defer:
      waitFor rpcClient.close()
      waitFor rpcLs.onExit()

    try:
      discard waitFor rpcClient.callRpc(
        "tools/call", %*{"name": "nimCheckProject", "arguments": {}}
      )
      checkpoint "tools/call was answered before initialize"
      fail()
    except JsonRpcError as err:
      check "-32002" in err.msg

    discard waitFor rpcClient.callRpc(
      "initialize",
      %*{
        "protocolVersion": McpProtocolVersion,
        "capabilities": {},
        "clientInfo": {"name": "nimlangserver tests", "version": "1"},
      },
    )
    let checkProject = waitFor rpcClient.callRpc(
      "tools/call", %*{"name": "nimCheckProject", "arguments": {}}
    )
    check checkProject{"content"}[0]{"text"}.getStr.startsWith("Invalid arguments: ")

  test "listTools returns all MCP tools":
    # initialize is required first; from a directory with no nimble project it
    # does not start a nimsuggest.
    let
      emptyDir = getTempDir() / "nimlangserver-mcp-no-project"
      savedDir = os.getCurrentDir()
    createDir(emptyDir)
    setCurrentDir(emptyDir)
    defer:
      setCurrentDir(savedDir)

    let
      rpcCmdParams = CommandLineParams(
        mode: some ServerMode.mcp,
        transport: some TransportMode.socket,
        port: getNextFreePort(),
      )
      rpcLs = main(rpcCmdParams)
      rpcClient = waitFor newMcpSocketClient(rpcCmdParams.port)

    defer:
      waitFor rpcClient.close()
      waitFor rpcLs.onExit()

    discard waitFor rpcClient.callRpc(
      "initialize",
      %*{
        "protocolVersion": McpProtocolVersion,
        "capabilities": {},
        "clientInfo": {"name": "nimlangserver tests", "version": "1"},
      },
    )

    let tools = (waitFor rpcClient.callRpc("tools/list", %*{}))["tools"].getElems

    check tools.mapIt(it["name"].getStr) ==
      @[
        "nimFindReferences", "nimFindSymbols", "nimListSymbols", "nimCheckProject",
        "nimCheckFile", "nimFindTypeDefinition",
      ]

    proc required(tool: JsonNode, schema: string): seq[string] =
      tool[schema]["required"].getElems.mapIt(it.getStr)

    let
      findReferences = tools[0]
      findSymbols = tools[1]
      listSymbols = tools[2]
      checkProject = tools[3]
      checkFile = tools[4]
      findTypeDefinition = tools[5]

    check findReferences.required("inputSchema") == @["path", "line", "column"]
    check findReferences.required("outputSchema") == @["refs"]
    check findSymbols.required("inputSchema") == @["uri", "query"]
    check findSymbols.required("outputSchema") == @["syms"]
    check listSymbols.required("inputSchema") == @["path"]
    check listSymbols.required("outputSchema") == @["syms"]
    check checkProject.required("inputSchema") == @["uri"]
    check checkProject.required("outputSchema") == @["diags"]
    check checkFile.required("inputSchema") == @["path"]
    check checkFile.required("outputSchema") == @["diags"]
    check findTypeDefinition.required("inputSchema") == @["path", "line", "column"]
    check findTypeDefinition.required("outputSchema") == @["defs"]

    #The property schemas are written as JSON, not as strings
    let inputProperties = findReferences["inputSchema"]["properties"]
    check inputProperties["line"] == %*{"type": "integer"}
    check findSymbols["inputSchema"]["properties"]["uri"] ==
      %*{"type": "string", "format": "uri"}
    let items = findReferences["outputSchema"]["properties"]["refs"]["items"]
    check items["properties"]["path"] == %*{"type": "string"}
    check items["required"].getElems.mapIt(it.getStr) == @["path", "line", "column"]

suite "MCP tools":
  let
    testProjectDir = absolutePath("tests" / "projects" / "mcpproject")
    savedDir = os.getCurrentDir()

  setCurrentDir(testProjectDir)

  let
    entryPoint = absolutePath("src" / "mcpproject.nim")
    errFile = absolutePath("src" / "mcpproject" / "errmodule.nim")
    testFile = absolutePath("tests" / "test1.nim")
    notifications = new seq[string]
    (ls, _) = waitFor initMcpServer(entryPoint, notifications)

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()
    setCurrentDir(savedDir)

  test "project tools work in a fresh session with no open file":
    # MCP initialize starts no nimsuggest, so the uri alone must resolve the
    # project.
    let (freshLs, _) = waitFor initMcpServer(entryPoint)
    defer:
      waitFor freshLs.shutdownNimsuggest()

    check freshLs.projectFiles.len == 0
    let symbols = waitFor mcp.callTool(
      freshLs,
      McpCallToolRequestParams(
        name: "nimFindSymbols",
        arguments: toolArguments(%*{"uri": errFile.Path.pathToUri, "query": "add"}),
      ),
    )
    checkToolResult(symbols)
    check symbols.structuredContent.get.string.parseJson["syms"].getElems().anyIt(
      it["path"].getStr() == entryPoint and it["kind"].getStr() == "Proc"
    )

    let diags = waitFor mcp.callTool(
      freshLs,
      McpCallToolRequestParams(
        name: "nimCheckProject", arguments: toolArguments(%*{"uri": entryPoint.Path.pathToUri})
      ),
    )
    checkToolResult(diags)
    check diags.structuredContent.get.string.parseJson["diags"].getElems().anyIt(
      it["path"].getStr() == errFile and it["severity"].getStr() == "Error"
    )

  test "callTool nimFindReferences returns structured references":
    let res = waitFor mcp.callTool(
      ls,
      McpCallToolRequestParams(
        name: "nimFindReferences",
        arguments: toolArguments(%*{"path": entryPoint, "line": 3, "column": 10}),
      ),
    )

    checkToolResult(res)

    let refs = res.structuredContent.get.string.parseJson["refs"].getElems()

    check len(refs) == 1

  test "callTool nimFindSymbols returns matching workspace symbols":
    let res = waitFor mcp.callTool(
      ls,
      McpCallToolRequestParams(
        name: "nimFindSymbols",
        arguments: toolArguments(%*{"uri": entryPoint.Path.pathToUri, "query": "add"}),
      ),
    )

    checkToolResult(res)

    let syms = res.structuredContent.get.string.parseJson["syms"].getElems()

    check syms.anyIt(
      it["path"].getStr() == entryPoint and it["line"].getInt() == 3 and
        it["column"].getInt() == 5 and it["kind"].getStr() == "Proc"
    )

  test "callTool nimListSymbols returns file outline":
    let res = waitFor mcp.callTool(
      ls,
      McpCallToolRequestParams(name: "nimListSymbols", arguments: toolArguments(%*{"path": entryPoint})),
    )

    checkToolResult(res)

    let syms = res.structuredContent.get.string.parseJson["syms"].getElems()

    check syms.len == 1
    check syms.len >= 1 and
      syms[0] ==
      %*{"name": "add", "path": entryPoint, "line": 3, "column": 5, "kind": "Proc"}

  test "callTool nimCheckProject returns workspace diagnostics":
    let res = waitFor mcp.callTool(
      ls,
      McpCallToolRequestParams(
        name: "nimCheckProject", arguments: toolArguments(%*{"uri": errFile.Path.pathToUri})
      ),
    )

    checkToolResult(res)

    let diags = res.structuredContent.get.string.parseJson["diags"].getElems()
    check diags.len > 0
    check diags.anyIt(
      it["path"].getStr() == errFile and it["line"].getInt() == 5 and
        it["severity"].getStr() == "Error" and
        it["message"].getStr().contains("type mismatch")
    )

  test "callTool nimCheckFile returns file diagnostics":
    let res = waitFor mcp.callTool(
      ls, McpCallToolRequestParams(name: "nimCheckFile", arguments: toolArguments(%*{"path": errFile}))
    )

    checkToolResult(res)

    let diags = res.structuredContent.get.string.parseJson["diags"].getElems()
    check diags.len > 0
    check diags.anyIt(
      it["line"].getInt() == 5 and it["severity"].getStr() == "Error" and
        it["message"].getStr().contains("type mismatch")
    )

  test "callTool nimCheckFile outside srcDir returns file diagnostics":
    let res = waitFor mcp.callTool(
      ls, McpCallToolRequestParams(name: "nimCheckFile", arguments: toolArguments(%*{"path": testFile}))
    )

    checkToolResult(res)

    let diags = res.structuredContent.get.string.parseJson["diags"].getElems()
    check diags.len > 0
    check diags.anyIt(
      it["line"].getInt() == 5 and it["severity"].getStr() == "Error" and
        it["message"].getStr().contains("type mismatch")
    )

  test "callTool nimFindTypeDefinition returns type definition":
    let res = waitFor mcp.callTool(
      ls,
      McpCallToolRequestParams(
        name: "nimFindTypeDefinition",
        arguments: toolArguments(%*{"path": entryPoint, "line": 3, "column": 10}),
      ),
    )

    checkToolResult(res)

    let defs = res.structuredContent.get.string.parseJson["defs"].getElems()
    check defs.len > 0
    check defs.anyIt(
      it["name"].getStr() == "int" or it["type"].getStr().contains("int")
    )

  test "the tools leave no file open":
    # MCP has no didClose, so a file a tool opened would stay open, and keep
    # its nimsuggest, for the whole session.
    check ls.projectFiles.len > 0
    check ls.openFiles.len == 0

  test "the tools send no LSP notifications":
    # The MCP client only understands MCP, so window/showMessage,
    # extension/statusUpdate and publishDiagnostics must not reach it.
    check ls.projectFiles.len > 0
    check notifications[].len == 0
