import ../[
  ls, lstransports
]

import ../protocol/types
import std/[options, unittest, json, os, jsonutils]
import json_rpc/[rpcclient]
import chronicles

type 
  LspSocketClient* = ref object of RpcSocketClient


proc newLspSocketClient*(): LspSocketClient = LspSocketClient.new()

method call*(client: LspSocketClient, name: string,
             params: JsonNode): Future[JsonString] {.async, gcsafe.} =
  ## Remotely calls the specified RPC method.
  let id = client.getNextId()
  let reqJson = newJObject()
  reqJson["jsonrpc"] = %"2.0"
  reqJson["id"] = %id.num
  reqJson["method"] = %name
  reqJson["params"] = params
  let reqContent = wrapContentWithContentLenght($reqJson)
  var jsonBytes = reqContent
  if client.transport.isNil:
    raise newException(JsonRpcError,
                    "Transport is not initialised (missing a call to connect?)")
  # completed by processMessage.
  var newFut = newFuture[JsonString]()
  # add to awaiting responses
  client.awaiting[id] = newFut

  let res = await client.transport.write(jsonBytes)
  # TODO: Add actions when not full packet was send, e.g. disconnect peer.
  doAssert(res == jsonBytes.len)

  return await newFut

proc processData(client: LspSocketClient) {.async: (raises: []).} =
  while true:
    var localException: ref JsonRpcError
    while true:
      try:
        # var value = await client.transport.readLine(defaultMaxRequestLength)
        var value = await processContentLength(client.transport)
        if value == "":
          # transmission ends
          await client.transport.closeWait()
          break
        
        let res = client.processMessage(value)
        if res.isErr:
          error "Error when processing RPC message", msg=res.error
          localException = newException(JsonRpcError, res.error)
          break
      except TransportError as exc:
        localException = newException(JsonRpcError, exc.msg)
        await client.transport.closeWait()
        break
      except CancelledError as exc:
        localException = newException(JsonRpcError, exc.msg)
        await client.transport.closeWait()
        break

    if localException.isNil.not:
      for _,fut in client.awaiting:
        fut.fail(localException)
      if client.batchFut.isNil.not and not client.batchFut.completed():
        client.batchFut.fail(localException)

    # async loop reconnection and waiting
    try:
      info "Reconnect to server", address=`$`(client.address)
      client.transport = await connect(client.address)
    except TransportError as exc:
      error "Error when reconnecting to server", msg=exc.msg
      break
    except CancelledError as exc:
      error "Error when reconnecting to server", msg=exc.msg
      break

proc onProcessMessage(client: RpcClient, line: string): Result[bool, string] {.gcsafe, raises: [].} = 
  # echo "onProcessmessage ", line #line contains the json response from the server. From here one could implement an actual client
  return ok(true)

proc connect*(client: LspSocketClient, address: string, port: Port) {.async.} =
  let addresses = resolveTAddress(address, port)
  client.transport = await connect(addresses[0])
  client.address = addresses[0]
  client.loop = processData(client)
  client.onProcessMessage = onProcessMessage