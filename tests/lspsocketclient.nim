## LSP socket client for tests — identical to tests/lspsocketclient.nim but
## updated import paths for the new src/ module hierarchy.

import ../src/langserver/[transports, utils]
import ../src/utils/utils
import ../src/utils/process_utils
export process_utils.getNextFreePort
import ../src/langserver/langserver_types
import ../src/protocol/types
import std/[options, unittest, json, os, jsonutils, tables, strutils, sequtils, sugar]
import json_rpc/[rpcclient]
import chronicles

# fixture paths are still under tests/ (shared with original test suite)
proc fixtureUri*(path: string): string =
  result = pathToUri(getCurrentDir() / "tests" / path)

type
  NotificationRpc* = proc(params: JsonNode): Future[void] {.async.}
  Rpc* = proc(params: JsonNode): Future[JsonNode] {.async.}
  LspSocketClient* = ref object of RpcSocketClient
    notifications*: TableRef[string, NotificationRpc]
    routes*: TableRef[string, Rpc]
    calls*: TableRef[string, seq[JsonNode]]
    responses*: TableRef[int, Future[JsonNode]]

proc newLspSocketClient*(): LspSocketClient =
  result = LspSocketClient.new()
  result.routes = newTable[string, Rpc]()
  result.notifications = newTable[string, NotificationRpc]()
  result.calls = newTable[string, seq[JsonNode]]()
  result.responses = newTable[int, Future[JsonNode]]()
  # Respond to workspace/configuration so configReady fires after initialize.
  result.routes["workspace/configuration"] = proc(params: JsonNode): Future[JsonNode] {.async.} =
    return newJArray()

method call*(
    client: LspSocketClient, name: string, params: JsonNode
): Future[JsonNode] {.async.} =
  let id = client.getNextId()
  let reqJson = newJObject()
  reqJson["jsonrpc"] = %"2.0"
  reqJson["id"] = %id.num
  reqJson["method"] = %name
  reqJson["params"] = params
  let reqContent = wrapContentWithContentLength($reqJson)
  var jsonBytes = reqContent
  if client.transport.isNil:
    raise newException(
      JsonRpcError, "Transport is not initialised (missing a call to connect?)"
    )
  var newFut = newFuture[JsonNode]()
  client.responses[id.num] = newFut
  let res = await client.transport.write(jsonBytes)
  return await newFut

proc runRpc(client: LspSocketClient, rpc: Rpc, serverReq: JsonNode) {.async.} =
  let res = await rpc(serverReq["params"])
  let id = serverReq["id"].jsonTo(string)
  let reqJson = newJObject()
  reqJson["jsonrpc"] = %"2.0"
  reqJson["id"] = %id
  reqJson["result"] = res
  let reqContent = wrapContentWithContentLength($reqJson)
  discard await client.transport.write(reqContent.string)

proc processMessage(client: LspSocketClient, msg: string) {.raises: [].} =
  try:
    let serverReq = msg.parseJson()
    if "method" in serverReq:
      let meth = serverReq["method"].jsonTo(string)
      debug "[Process Data Loop ]", meth = meth
      if "id" in serverReq:
        if meth in client.routes:
          asyncSpawn runRpc(client, client.routes[meth], serverReq)
        else:
          error "Route not implemented ", meth = meth
      else:
        if meth in client.notifications:
          asyncSpawn client.notifications[meth](serverReq["params"])
        else:
          error "Method not implemented ", meth = meth
    elif "id" in serverReq:
      let id = serverReq["id"].jsonTo(int)
      client.responses[id].complete(serverReq["result"])
    else:
      error "Unknown msg", msg = msg
  except CatchableError as exc:
    error "ProcessData Error ", msg = exc.msg

proc processData(client: LspSocketClient) {.async: (raises: []).} =
  while true:
    var localException: ref JsonRpcError
    while true:
      try:
        var value = await processContentLength(client.transport)
        if value == "":
          await client.transport.closeWait()
          break
        client.processMessage(value)
      except TransportError as exc:
        localException = newException(JsonRpcError, exc.msg)
        await client.transport.closeWait()
        break
      except CancelledError as exc:
        localException = newException(JsonRpcError, exc.msg)
        await client.transport.closeWait()
        break

    if localException.isNil.not:
      for _, fut in client.awaiting:
        fut.fail(localException)
      if client.batchFut.isNil.not and not client.batchFut.completed():
        client.batchFut.fail(localException)

    try:
      info "Reconnect to server", address = `$`(client.address)
      client.transport = await connect(client.address)
    except TransportError as exc:
      error "Error when reconnecting to server", msg = exc.msg
      break
    except CancelledError as exc:
      error "Error when reconnecting to server", msg = exc.msg
      break

proc connect*(client: LspSocketClient, address: string, port: Port) {.async.} =
  let addresses = resolveTAddress(address, port)
  client.transport = await connect(addresses[0])
  client.address = addresses[0]
  client.loop = processData(client)

proc notify*(client: LspSocketClient, name: string, params: JsonNode) =
  proc wrap(): Future[void] {.async.} =
    discard await client.call(name, params)
  asyncSpawn wrap()

proc register*(client: LspSocketClient, name: string, notRpc: NotificationRpc) =
  client.notifications[name] = notRpc
  client.calls[name] = newSeq[JsonNode]()

proc register*(client: LspSocketClient, name: string, rpc: Rpc) =
  client.routes[name] = rpc

proc initialize*(
    client: LspSocketClient, initParams: LspInitializeParams
): Future[LspInitializeResult] {.async.} =
  client.call("initialize", %initParams).await.jsonTo(
    LspInitializeResult, Joptions(allowMissingKeys: true)
  )

proc createDidOpenParams*(file: string): DidOpenTextDocumentParams =
  return
    DidOpenTextDocumentParams %* {
      "textDocument": {
        "uri": fixtureUri(file),
        "languageId": "nim",
        "version": 0,
        "text": readFile("tests" / file),
      }
    }

proc positionParams*(uri: string, line, character: int): TextDocumentPositionParams =
  return
    TextDocumentPositionParams %*
    {"position": {"line": line, "character": character}, "textDocument": {"uri": uri}}

proc notificationHandle*(
    args: (LspSocketClient, string), params: JsonNode
): Future[void] =
  try:
    let client = args[0]
    let name = args[1]
    if name in ["textDocument/publishDiagnostics", "$/progress"]:
      debug "[NotificationHandled ] Called for ", name = name
    else:
      debug "[NotificationHandled ] Called for ", name = name, params = params
    client.calls[name].add params
  except CatchableError:
    discard
  result = newFuture[void]("notificationHandle")

proc registerNotification*(client: LspSocketClient, names: varargs[string]) =
  for name in names:
    client.register(name, partial(notificationHandle, (client, name)))

proc waitForNotification*(
    client: LspSocketClient,
    name: string,
    predicate: proc(json: JsonNode): bool {.gcsafe, raises: [CatchableError].},
    timeoutMs: int = 10000,
): Future[bool] {.async.} =
  ## Poll `client.calls[name]` every 100ms until predicate matches or timeoutMs elapses.
  ## Uses a while loop instead of tail recursion to avoid accumulating Future objects.
  let timeout = if timeoutMs == 0: 10000 else: timeoutMs
  var elapsed = 0
  while elapsed <= timeout:
    try:
      for call in client.calls[name]:
        if predicate(call):
          debug "[WaitForNotification Predicate Matches] ", name = name, call = call
          return true
    except CatchableError as ex:
      error "[WaitForNotification]", ex = ex.msg
    await sleepAsync(100)
    elapsed += 100
  error "Couldn't match predicate ", calls = client.calls[name]
  return false

proc waitForNotificationMessage*(
    client: LspSocketClient, msg: string, timeoutMs: int = 10000
): Future[bool] {.async.} =
  return await waitForNotification(
    client, "window/showMessage", (json: JsonNode) => json["message"].to(string) == msg,
    timeoutMs,
  )
