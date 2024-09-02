import ../[
  ls, lstransports, utils
]

import ../protocol/types
import std/[options, unittest, json, os, jsonutils, tables, strutils, sequtils]
import json_rpc/[rpcclient]
import chronicles

#Utils
proc fixtureUri*(path: string): string =
  result = pathToUri(getCurrentDir() / "tests" / path)

type 
  NotificationRpc* = proc (params: JsonNode): Future[void] {.gcsafe, raises:[].}
  Rpc* = proc (params: JsonNode): Future[JsonNode] {.gcsafe, raises:[].}
  LspSocketClient* = ref object of RpcSocketClient
    notifications*: TableRef[string, NotificationRpc]
    routes*: TableRef[string, Rpc]
    calls*: TableRef[string, seq[JsonNode]] #Stores all requests here from the server so we can test on them


proc newLspSocketClient*(): LspSocketClient = 
  result = LspSocketClient.new()
  result.routes = newTable[string, Rpc]()
  result.notifications = newTable[string, NotificationRpc]()
  result.calls = newTable[string, seq[JsonNode]]()

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

# proc processMessage*(client: LspSocketClient, msg: string): Future[void] {.async: (raises: []).} =
#   try:
#     echo "process message ", msg
#     let msg = msg.parseJson()
#     if "id" in msg and msg["id"].kind == JInt: #TODO this is just a response from the server
#       echo "Response from Server"
#       await sleepAsync(1)
      

#       # let res = newJObject()
#       # res["rpc"]
#       #Here we should write in the transport the request i.e. 
#       # discard await client.transport.write()
    
#   except CatchableError as ex: 
#     error "Processing message error ", ex = ex.msg

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


proc processClientLoop*(client: LspSocketClient) {.async: (raises: []), gcsafe.} =
  while true:
    # if not client.transport.isOpen:
    try:
      await sleepAsync(100)
      
      let msg = await processContentLength(client.transport, error = false)
      if msg == "": continue
      let serverReq = msg.parseJson()      
      let meth = serverReq["method"].jsonTo(string)
      debug "[Process client loop ]", meth = meth
      if meth in client.notifications:
        await client.notifications[meth](serverReq["params"])
      elif meth in client.routes:
        #TODO extract
        let res = await client.routes[meth](serverReq["params"])
        let id = serverReq["id"].jsonTo(string)
        let reqJson = newJObject()
        reqJson["jsonrpc"] = %"2.0"
        reqJson["id"] = %id
        reqJson["result"] = res
        let reqContent = wrapContentWithContentLenght($reqJson)
        discard await client.transport.write(reqContent.string)

        debug "***********Response in ", res = $res, req = serverReq

      else:
        error "Method not found in client", meth = meth
       
    except CatchableError as ex:
      error "[ProcessClientLoop ]", ex = ex.msg
      discard 

proc connect*(client: LspSocketClient, address: string, port: Port) {.async.} =
  let addresses = resolveTAddress(address, port)
  client.transport = await connect(addresses[0])
  client.address = addresses[0]
  client.loop = processData(client)
  asyncSpawn client.processClientLoop()
  

proc notify*(client: LspSocketClient, name: string, params: JsonNode) =
  proc wrap(): Future[void] {.async.} = 
    discard await client.call(name, params)
  asyncSpawn wrap()


proc register*(client: LspSocketClient, name: string, notRpc: NotificationRpc ) = 
  client.notifications[name] = notRpc
  client.calls[name] = newSeq[JsonNode]()

proc register*(client: LspSocketClient, name: string, rpc: Rpc) = 
  client.routes[name] = rpc
  
#Calls
proc initialize*(client: LspSocketClient): Future[InitializeResult] {.async.} = 
  let initParams = InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/hw/"),
        "capabilities": {
          "window": {
            "workDoneProgress": true
          },
          "workspace": {"configuration": true}
        }
    }
  client.call("initialize", %initParams).await.string.parseJson.jsonTo(InitializeResult)
  #Should we await here for the response to come back?




proc createDidOpenParams*(file: string): DidOpenTextDocumentParams =
  return DidOpenTextDocumentParams %* {
    "textDocument": {
      "uri": fixtureUri(file),
      "languageId": "nim",
      "version": 0,
      "text": readFile("tests" / file)
     }
  }

proc positionParams*(uri: string, line, character: int): TextDocumentPositionParams =
  return TextDocumentPositionParams %* {
      "position": {
         "line": line,
         "character": character
      },
      "textDocument": {
         "uri": uri
       }
    }