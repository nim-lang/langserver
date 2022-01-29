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

proc fixtureUri(path: string): string =
  result = pathToUri(getCurrentDir() / "tests" / path)

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
      rootUri: fixtureUri("projects/hw/"),
      capabilities: ClientCapabilities())

  discard waitFor clientConnection.call("initialize", %initParams)
  waitFor clientConnection.notify("initialized", newJObject())

  let didOpenParams = DidOpenTextDocumentParams <% {
    "textDocument": {
      "uri": fixtureUri("projects/hw/hw.nim"),
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
         "uri": fixtureUri("projects/hw/hw.nim")
       }
    }
    let hover = to(waitFor clientConnection.call("textDocument/hover",
                                                 %hoverParams),
                   Hover)
    let expected = Hover <% {
      "contents": [{
          "language": "nim",
          "value": ": proc (){.noSideEffect, gcsafe, locks: 0.}"
        }, {
          "language": "markdown",
          "value": "\"\""
        }
      ],
      "range": nil
    }

    doAssert %hover == %expected

  test "Sending hover(no content)":
    let hoverParams = HoverParams <% {
      "position": {
         "line": 2,
         "character": 0
      },
      "textDocument": {
         "uri": fixtureUri("projects/hw/hw.nim")
       }
    }
    let hover = waitFor clientConnection.call("textDocument/hover", %hoverParams)
    doAssert hover.kind == JNull
  test

  pipeClient.close()
  pipeServer.close()
