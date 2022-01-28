import
  std/json,
  os,
  unittest,
  jsonschema,
  json_rpc/jsonmarshal,
  faststreams/async_backend,
  faststreams/asynctools_adapters,
  json_rpc/streamconnection,
  ../nls,
  ../protocol/types


suite "Client/server initialization sequence":
  let pipeServer = createPipe();
  let pipeClient = createPipe();

  let serverConnection = StreamConnection.new(pipeClient, pipeServer);
  registerLanguageServerHandlers(serverConnection);
  discard serverConnection.start();

  let clientConnection = StreamConnection.new(pipeServer, pipeClient);
  discard clientConnection.start();

  test "Sending initialize.":
    let initParams = InitializeParams(
        processId: %getCurrentProcessId(),
        rootUri: "file:///tmp/",
        capabilities: ClientCapabilities())

    let initializeResult = waitFor clientConnection.call("initialize", %initParams)
    doAssert initializeResult != nil;

    waitFor clientConnection.notify("initialized", newJObject())

  pipeClient.close()
  pipeServer.close()

suite "LSP features":
  let pipeServer = createPipe();
  let pipeClient = createPipe();

  let serverConnection = StreamConnection.new(pipeClient, pipeServer);
  registerLanguageServerHandlers(serverConnection);
  discard serverConnection.start();

  let clientConnection = StreamConnection.new(pipeServer, pipeClient);
  discard clientConnection.start();

  let initParams = InitializeParams(
      processId: %getCurrentProcessId(),
      rootUri: "file:///home/yyoncho/Sources/nim/langserver/tests/projects/hw/",
      capabilities: ClientCapabilities())

  discard waitFor clientConnection.call("initialize", %initParams)
  waitFor clientConnection.notify("initialized", newJObject())

  let didOpenParams = DidOpenTextDocumentParams <% {
    "textDocument": {
      "uri": "file:///home/yyoncho/Sources/nim/langserver/tests/projects/hw/hw.nim",
      "languageId": "nim",
      "version": 0,
      "text": readFile("tests/projects/hw/hw.nim")
     }
   }

  discard clientConnection.notify("textDocument/didOpen", %didOpenParams)

  test "Sending hover.":
    let hoverParams = HoverParams <% {
      "position": {
         "line": 1,
         "character": 0
      },
      "textDocument": {
         "uri": "file:///home/yyoncho/Sources/nim/langserver/tests/projects/hw/hw.nim"
       }
    }
    let hover = to(waitFor clientConnection.call("textDocument/hover",
                                                 %hoverParams),
                   Hover)
    doAssert hover.contents.getStr == "proc (){.noSideEffect, gcsafe, locks: 0.}"

  test "Sending hover(no content)":
    let hoverParams = HoverParams <% {
      "position": {
         "line": 2,
         "character": 0
      },
      "textDocument": {
         "uri": "file:///home/yyoncho/Sources/nim/langserver/tests/projects/hw/hw.nim"
       }
    }
    let hover = waitFor clientConnection.call("textDocument/hover", %hoverParams)
    doAssert hover.kind == JNull

  pipeClient.close()
  pipeServer.close()
