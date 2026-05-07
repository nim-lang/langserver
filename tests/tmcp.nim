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

proc newTestLs(cmdParams: CommandLineParams): LanguageServer =
  result = initLs(cmdParams, ensureStorageDir())
  result.notify = proc(name: string, params: JsonNode) =
    discard
  result.call = proc(name: string, params: JsonNode): Future[JsonNode] {.async.} =
    newJNull()
  result.onExit = proc(): Future[void] {.async.} =
    discard

proc newMcpInitParams(): McpInitializeParams =
  McpInitializeParams %* {
    "protocolVersion": McpProtocolVersion,
    "capabilities": {},
    "clientInfo": {"name": "nimble test", "version": "1"},
  }

proc checkToolResult(res: McpCallToolResult) =
  check res.isError == false
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
  let cmdParams =
    CommandLineParams(mode: some ServerMode.mcp, transport: some TransportMode.stdio)
  let ls = newTestLs(cmdParams)
  let initParams = newMcpInitParams()
  let initializeResult = waitFor mcp.initialize((ls: ls, onExit: ls.onExit), initParams)

  let repoMainFile = absolutePath("nimlangserver.nim")
  discard waitFor ls.projectFiles[repoMainFile].ns

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "initialize returns MCP capabilities":
    check initializeResult.protocolVersion == McpProtocolVersion
    check initializeResult.serverInfo.name == "nimlangserver"
    check initializeResult.serverInfo.version == LSPVersion

    check ls.mcpInitializeParams.protocolVersion == McpProtocolVersion

    check ls.entryPoints.len > 0
    check ls.entryPoints.allIt(it == repoMainFile)

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
        "nimCheckFile",
      ]

    let
      findReferences = listToolsResult.tools[0]
      findSymbols = listToolsResult.tools[1]
      listSymbols = listToolsResult.tools[2]
      checkProject = listToolsResult.tools[3]
      checkFile = listToolsResult.tools[4]

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

  test "callTool nimFindReferences returns structured references":
    let testProjectDir = absolutePath("tests" / "projects" / "mcpproject")

    cd testProjectDir:
      let
        testLs = newTestLs(cmdParams)
        entryPoint = absolutePath("src" / "mcpproject.nim")

      defer:
        waitFor testLs.stopNimsuggestProcesses()

      discard
        waitFor mcp.initialize((ls: testLs, onExit: testLs.onExit), newMcpInitParams())
      discard waitFor testLs.projectFiles[entryPoint].ns

      let res = waitFor mcp.callTool(
        testLs,
        McpCallToolParams(
          name: "nimFindReferences",
          arguments: some %*{"path": entryPoint, "line": 3, "column": 10},
        ),
      )

      checkToolResult(res)

      let refs = res.structuredContent["refs"].getElems()
      check refs.len == 1

  test "callTool nimFindSymbols returns matching workspace symbols":
    let testProjectDir = absolutePath("tests" / "projects" / "mcpproject")

    cd testProjectDir:
      let
        testLs = newTestLs(cmdParams)
        entryPoint = absolutePath("src" / "mcpproject.nim")

      defer:
        waitFor testLs.stopNimsuggestProcesses()

      discard
        waitFor mcp.initialize((ls: testLs, onExit: testLs.onExit), newMcpInitParams())
      discard waitFor testLs.projectFiles[entryPoint].ns

      let res = waitFor mcp.callTool(
        testLs, McpCallToolParams(name: "nimFindSymbols", arguments: some %*{"query": "add"})
      )

      checkToolResult(res)

      let syms = res.structuredContent["syms"].getElems()

      check syms.anyIt(
        it["path"].getStr() == entryPoint and it["line"].getInt() == 3 and
          it["column"].getInt() == 5 and it["kind"].getStr() == "Proc"
      )

  test "callTool nimListSymbols returns file outline":
    let testProjectDir = absolutePath("tests" / "projects" / "mcpproject")

    cd testProjectDir:
      let
        testLs = newTestLs(cmdParams)
        entryPoint = absolutePath("src" / "mcpproject.nim")

      defer:
        waitFor testLs.stopNimsuggestProcesses()

      discard
        waitFor mcp.initialize((ls: testLs, onExit: testLs.onExit), newMcpInitParams())
      discard waitFor testLs.projectFiles[entryPoint].ns

      let res = waitFor mcp.callTool(
        testLs,
        McpCallToolParams(name: "nimListSymbols", arguments: some %*{"path": entryPoint}),
      )

      checkToolResult(res)

      let syms = res.structuredContent["syms"].getElems()
      check syms.len == 1
      check syms[0] ==
        %*{"name": "add", "path": entryPoint, "line": 3, "column": 5, "kind": "Proc"}

  test "callTool nimCheckProject returns workspace diagnostics":
    let testProjectDir = absolutePath("tests" / "projects" / "mcpproject")

    cd testProjectDir:
      let
        testLs = newTestLs(cmdParams)
        entryPoint = absolutePath("src" / "mcpproject.nim")
        errFile = absolutePath("src" / "mcpproject" / "errmodule.nim")

      defer:
        waitFor testLs.stopNimsuggestProcesses()

      discard
        waitFor mcp.initialize((ls: testLs, onExit: testLs.onExit), newMcpInitParams())
      discard waitFor testLs.projectFiles[entryPoint].ns

      let res = waitFor mcp.callTool(testLs, McpCallToolParams(name: "nimCheckProject"))

      checkToolResult(res)

      let diags = res.structuredContent["diags"].getElems()
      check diags.len > 0
      check diags.anyIt(
        it["path"].getStr() == errFile and it["line"].getInt() == 5 and
          it["severity"].getStr() == "Error" and
          it["message"].getStr().contains("type mismatch")
      )

  test "callTool nimCheckFile returns file diagnostics":
    let testProjectDir = absolutePath("tests" / "projects" / "mcpproject")

    cd testProjectDir:
      let
        testLs = newTestLs(cmdParams)
        entryPoint = absolutePath("src" / "mcpproject.nim")
        errFile = absolutePath("src" / "mcpproject" / "errmodule.nim")

      defer:
        waitFor testLs.stopNimsuggestProcesses()

      discard
        waitFor mcp.initialize((ls: testLs, onExit: testLs.onExit), newMcpInitParams())
      discard waitFor testLs.projectFiles[entryPoint].ns

      let res = waitFor mcp.callTool(
        testLs, McpCallToolParams(name: "nimCheckFile", arguments: some %*{"path": errFile})
      )

      checkToolResult(res)

      let diags = res.structuredContent["diags"].getElems()
      check diags.len > 0
      check diags.anyIt(
        it["line"].getInt() == 5 and it["severity"].getStr() == "Error" and
          it["message"].getStr().contains("type mismatch")
      )

  test "callTool nimCheckFile outside srcDir returns file diagnostics":
    let testProjectDir = absolutePath("tests" / "projects" / "mcpproject")

    cd testProjectDir:
      let
        testLs = newTestLs(cmdParams)
        entryPoint = absolutePath("src" / "mcpproject.nim")
        testFile = absolutePath("tests" / "test1.nim")

      defer:
        waitFor testLs.stopNimsuggestProcesses()

      discard
        waitFor mcp.initialize((ls: testLs, onExit: testLs.onExit), newMcpInitParams())
      discard waitFor testLs.projectFiles[entryPoint].ns

      let res = waitFor mcp.callTool(
        testLs, McpCallToolParams(name: "nimCheckFile", arguments: some %*{"path": testFile})
      )

      checkToolResult(res)

      let diags = res.structuredContent["diags"].getElems()
      check diags.len > 0
      check diags.anyIt(
        it["line"].getInt() == 5 and it["severity"].getStr() == "Error" and
          it["message"].getStr().contains("type mismatch")
      )
