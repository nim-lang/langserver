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

  test "Sending notification.":
    let initParams = InitializeParams(
        processId: %getCurrentProcessId(),
        rootUri: "file:///tmp/",
        capabilities: ClientCapabilities())

    let initializeResult = waitFor clientConnection.call("initialize", %initParams)
    assert initializeResult != nil;

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
      rootUri: "file:///tmp/",
      capabilities: ClientCapabilities())

  let initializeResult = waitFor clientConnection.call("initialize", %initParams)
  assert initializeResult != nil;

  waitFor clientConnection.notify("initialized", newJObject())

  test "Sending notification.":
    discard

  pipeClient.close()
  pipeServer.close()
