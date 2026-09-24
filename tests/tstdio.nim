## The stdio transport, served over a pair of pipes.
##
## A client that spawns `nimlangserver --stdio` finds the two pipes on its own
## descriptors; here they are made by hand instead, so the test runner keeps
## its own stdin and stdout. Everything past that is what the real thing does:
## `json_rpc`'s stdio client on one end, `ls.startStdioServer` on the other.

import ../[nimlangserver, ls, utils, lstransports2]
import ../protocol/types
import std/[options, json, jsonutils]
import chronos/osutils
import json_rpc/[clients/stdioclient, router]
import json_rpc/private/jrpc_sys
import unittest2

proc newPipePair(): tuple[rd, wr: StreamTransport] =
  const flags = {DescriptorFlag.NonBlock, DescriptorFlag.CloseOnExec}
  let pipe = createOsPipe(flags, flags).expect("os pipe")
  try:
    (fromPipe(AsyncFD(pipe.read)), fromPipe(AsyncFD(pipe.write)))
  except TransportOsError as ex:
    raiseAssert "Cannot wrap the pipe: " & ex.msg

proc params(node: JsonNode): RequestParamsTx =
  JrpcSys.decode($node, RequestParamsRx).toTx

suite "Nimlangserver stdio transport":
  let ls =
    initLs(CommandLineParams(mode: some lsp, transport: some stdio), ensureStorageDir())
  ls.initServer()
  ls.registerRoutes()

  #Two pipes, one per direction, as a spawned process would be given
  let
    (srvIn, cliOut) = newPipePair() #client -> server
    (cliIn, srvOut) = newPipePair() #server -> client
  ls.startStdioServer(srvIn, srvOut)

  var
    statusUpdate = newFuture[JsonNode]("extension/statusUpdate")
    clientRouter = new(RpcRouter)
  clientRouter[] = RpcRouter.init()
  clientRouter[].register(
    "extension/statusUpdate",
    proc(params: RequestParamsRx): Future[JsonString] {.gcsafe, async.} =
      #The test is single threaded, `statusUpdate` is only ever touched here
      {.cast(gcsafe).}:
        if not statusUpdate.finished:
          statusUpdate.complete(parseJson(JrpcSys.encode(params.toTx)))
      JsonString("null"),
  )

  let client = RpcStdioClient.new(router = clientRouter, framing = Framing.httpHeader())
  client.loop = client.attach(cliIn, cliOut, "stdio")

  test "The connection is served as soon as the server is started":
    check not ls.connection.isNil

  test "initialize is answered over stdio":
    let initParams = params(
      %*{"processId": nil, "rootUri": nil, "capabilities": {}, "workspaceFolders": nil}
    )
    let res = waitFor client.call("initialize", initParams).wait(30.seconds)
    let initRes =
      res.string.parseJson.jsonTo(LspInitializeResult, Joptions(allowMissingKeys: true))
    check not initRes.capabilities.completionProvider.isNil

  test "The server notifies the client over the same pipes":
    #`extension/statusUpdate` is pushed by the server on its own
    check (waitFor statusUpdate.wait(30.seconds)).hasKey("lspPath")

  test "shutdown is answered over the same connection":
    let res = waitFor client.call("shutdown", params(%*{})).wait(30.seconds)
    check res == JsonString("null")

  test "The transport is closed on exit":
    waitFor ls.onExit()
    check ls.connection.isNil
    waitFor client.close()
