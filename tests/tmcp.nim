import ../[nimlangserver, ls, lstransports, utils]
import ../protocol/types
import ../routes/mcp
import ./testhelpers
import std/[json, jsonutils, options, os, sequtils, strutils, tables]
import chronos
import unittest2

type McpSocketClient = ref object
  transport: StreamTransport
  nextId: int

proc initMcpServer(
    mainFile: string
): Future[(LanguageServer, McpInitializeResult)] {.async: (raises: [CatchableError]).} =
  let
    cmdParams =
      CommandLineParams(mode: some ServerMode.mcp, transport: some TransportMode.stdio)
    initParams =
      McpInitializeParams %* {
        "protocolVersion": McpProtocolVersion,
        "capabilities": {},
        "clientInfo": {"name": "nimble test", "version": "1"},
      }
    ls = initLs(cmdParams, ensureStorageDir())

  ls.notify = proc(name: string, params: JsonNode) {.gcsafe, raises: [].} =
    discard
  ls.call = proc(name: string, params: JsonNode): Future[JsonNode] {.async.} =
    newJNull()
  ls.onExit = proc(): Future[void] {.async.} =
    discard

  let initRes = await mcp.initialize((ls: ls, onExit: ls.onExit), initParams)

  (ls, initRes)

proc checkToolResult(res: McpCallToolResult) =
  check not res.isError
  check parseJson(res.content[0].text) == res.structuredContent

proc newMcpSocketClient(port: Port): Future[McpSocketClient] {.async.} =
  let addresses = resolveTAddress("localhost", port)
  McpSocketClient(transport: await connect(addresses[0]))

proc close(client: McpSocketClient): Future[void] {.async.} =
  if not client.transport.isNil:
    await client.transport.closeWait()

proc readResponseLine(client: McpSocketClient): Future[string] {.async.} =
  while true:
    let chunk = await client.transport.read(1)
    if chunk.len == 0:
      return

    let ch = chunk[0].char
    if ch == '\n':
      return

    result.add(ch)

proc callRpc(
    client: McpSocketClient, name: string, params: JsonNode
): Future[JsonNode] {.async.} =
  inc client.nextId
  let id = client.nextId
  let reqJson = %*{"jsonrpc": "2.0", "id": id, "method": name, "params": params}
  discard await client.transport.write(wrapContentWithContentLength($reqJson))

  while true:
    let response = await client.readResponseLine()
    if response == "":
      raise newException(IOError, "MCP server disconnected")

    let responseJson = parseJson(response)
    if "id" in responseJson and responseJson["id"].getInt() == id:
      return responseJson["result"]

suite "MCP routes":
  let
    mainFile = absolutePath("nimlangserver.nim")
    (ls, initRes) = waitFor initMcpServer(mainFile)

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "initialize returns MCP info":
    check initRes.protocolVersion == McpProtocolVersion
    check initRes.serverInfo.name == "nimlangserver"
    check initRes.serverInfo.version == LSPVersion

  test "listTools returns all MCP tools":
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

    let listToolsResult =
      (waitFor rpcClient.callRpc("tools/list", %*{})).jsonTo(McpListToolsResult)

    check listToolsResult.tools.mapIt(it.name) ==
      @[
        "nimFindReferences", "nimFindSymbols", "nimListSymbols", "nimCheckProject",
        "nimCheckFile", "nimFindTypeDefinition",
      ]

    let
      findReferences = listToolsResult.tools[0]
      findSymbols = listToolsResult.tools[1]
      listSymbols = listToolsResult.tools[2]
      checkProject = listToolsResult.tools[3]
      checkFile = listToolsResult.tools[4]
      findTypeDefinition = listToolsResult.tools[5]

    check findReferences.inputSchema.required == @["path", "line", "column"]
    check findReferences.outputSchema.required == @["refs"]
    check findSymbols.inputSchema.required == @["query"]
    check findSymbols.outputSchema.required == @["syms"]
    check listSymbols.inputSchema.required == @["path"]
    check listSymbols.outputSchema.required == @["syms"]
    check checkProject.inputSchema.required.len == 0
    check checkProject.outputSchema.required == @["diags"]
    check checkFile.inputSchema.required == @["path"]
    check checkFile.outputSchema.required == @["diags"]
    check findTypeDefinition.inputSchema.required == @["path", "line", "column"]
    check findTypeDefinition.outputSchema.required == @["defs"]

suite "MCP tools":
  let
    testProjectDir = absolutePath("tests" / "projects" / "mcpproject")
    savedDir = getCurrentDir()

  setCurrentDir(testProjectDir)

  let
    entryPoint = absolutePath("src" / "mcpproject.nim")
    errFile = absolutePath("src" / "mcpproject" / "errmodule.nim")
    testFile = absolutePath("tests" / "test1.nim")
    (ls, _) = waitFor initMcpServer(entryPoint)

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()
    setCurrentDir(savedDir)

  test "callTool nimFindReferences returns structured references":
    let res = waitFor mcp.callTool(
      ls,
      McpCallToolParams(
        name: "nimFindReferences",
        arguments: some %*{"path": entryPoint, "line": 3, "column": 10},
      ),
    )

    checkToolResult(res)

    let refs = res.structuredContent["refs"].getElems()

    check len(refs) == 1

  test "callTool nimFindSymbols returns matching workspace symbols":
    let res = waitFor mcp.callTool(
      ls, McpCallToolParams(name: "nimFindSymbols", arguments: some %*{"query": "add"})
    )

    checkToolResult(res)

    let syms = res.structuredContent["syms"].getElems()

    check syms.anyIt(
      it["path"].getStr() == entryPoint and it["line"].getInt() == 3 and
        it["column"].getInt() == 5 and it["kind"].getStr() == "Proc"
    )

  test "callTool nimListSymbols returns file outline":
    let res = waitFor mcp.callTool(
      ls,
      McpCallToolParams(name: "nimListSymbols", arguments: some %*{"path": entryPoint}),
    )

    checkToolResult(res)

    let syms = res.structuredContent["syms"].getElems()

    check syms.len == 1
    check syms[0] ==
      %*{"name": "add", "path": entryPoint, "line": 3, "column": 5, "kind": "Proc"}

  test "callTool nimCheckProject returns workspace diagnostics":
    let res = waitFor mcp.callTool(ls, McpCallToolParams(name: "nimCheckProject"))

    checkToolResult(res)

    let diags = res.structuredContent["diags"].getElems()
    check diags.len > 0
    check diags.anyIt(
      it["path"].getStr() == errFile and it["line"].getInt() == 5 and
        it["severity"].getStr() == "Error" and
        it["message"].getStr().contains("type mismatch")
    )

  test "callTool nimCheckFile returns file diagnostics":
    let res = waitFor mcp.callTool(
      ls, McpCallToolParams(name: "nimCheckFile", arguments: some %*{"path": errFile})
    )

    checkToolResult(res)

    let diags = res.structuredContent["diags"].getElems()
    check diags.len > 0
    check diags.anyIt(
      it["line"].getInt() == 5 and it["severity"].getStr() == "Error" and
        it["message"].getStr().contains("type mismatch")
    )

  test "callTool nimCheckFile outside srcDir returns file diagnostics":
    let res = waitFor mcp.callTool(
      ls, McpCallToolParams(name: "nimCheckFile", arguments: some %*{"path": testFile})
    )

    checkToolResult(res)

    let diags = res.structuredContent["diags"].getElems()
    check diags.len > 0
    check diags.anyIt(
      it["line"].getInt() == 5 and it["severity"].getStr() == "Error" and
        it["message"].getStr().contains("type mismatch")
    )

  test "callTool nimFindTypeDefinition returns type definition":
    let res = waitFor mcp.callTool(
      ls,
      McpCallToolParams(
        name: "nimFindTypeDefinition",
        arguments: some %*{"path": entryPoint, "line": 3, "column": 10},
      ),
    )

    checkToolResult(res)

    let defs = res.structuredContent["defs"].getElems()
    check defs.len > 0
    check defs.anyIt(
      it["name"].getStr() == "int" or it["type"].getStr().contains("int")
    )

when defined(feature.nimlangserver.track):
  suite "MCP tools with nim track":
    let
      testProjectDir = absolutePath("tests" / "projects" / "mcpproject")
      savedDir = getCurrentDir()

    setCurrentDir(testProjectDir)

    let
      entryPoint = absolutePath("src" / "mcpproject.nim")
      (ls, _) = waitFor initMcpServer(entryPoint)

    let conf = NlsConfig(useNimTrack: some true)
    ls.workspaceConfiguration.complete(% @[conf])

    suiteTeardown:
      waitFor ls.stopNimsuggestProcesses()
      setCurrentDir(savedDir)

    test "callTool nimFindReferences with nim track":
      let res = waitFor mcp.callTool(
        ls,
        McpCallToolParams(
          name: "nimFindReferences",
          arguments: some %*{"path": entryPoint, "line": 3, "column": 10},
        ),
      )

      checkToolResult(res)
