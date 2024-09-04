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
    responses*: TableRef[int, Future[JsonNode]] #id -> response. Stores the responses to the calls 

proc newLspSocketClient*(): LspSocketClient = 
  result = LspSocketClient.new()
  result.routes = newTable[string, Rpc]()
  result.notifications = newTable[string, NotificationRpc]()
  result.calls = newTable[string, seq[JsonNode]]()
  result.responses = newTable[int, Future[JsonNode]]()

method call*(client: LspSocketClient, name: string,
             params: JsonNode): Future[JsonNode] {.async, gcsafe.} =
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
  # completed by processData.
  var newFut = newFuture[JsonNode]()
  # add to awaiting responses
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
  let reqContent = wrapContentWithContentLenght($reqJson)
  discard await client.transport.write(reqContent.string)

proc processMessage(client: LspSocketClient, msg: string) {.raises:[].} = 
  try:
    let serverReq = msg.parseJson()   
    if "method" in serverReq:   
      let meth = serverReq["method"].jsonTo(string)
      debug "[Process Data Loop ]", meth = meth
      if meth in client.notifications:       
        asyncSpawn client.notifications[meth](serverReq["params"])
      elif meth in client.routes:        
        asyncSpawn runRpc(client, client.routes[meth], serverReq)
      else:
        error "Method not implemented ", meth = meth
    elif "id" in serverReq: #Response here
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
        # var value = await client.transport.readLine(defaultMaxRequestLength)
        var value = await processContentLength(client.transport)
        if value == "":
          # transmission ends
          await client.transport.closeWait()
          break
        # echo "----------------------------ProcessData----------------------"
        # echo value
        # echo "----------------------------EndProcessData-------------------"        
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

proc connect*(client: LspSocketClient, address: string, port: Port) {.async.} =
  let addresses = resolveTAddress(address, port)
  client.transport = await connect(addresses[0])
  client.address = addresses[0]
  client.loop = processData(client)
  

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
proc initialize*(client: LspSocketClient, initParams: InitializeParams): Future[InitializeResult] {.async.} = 
  client.call("initialize", %initParams).await.jsonTo(InitializeResult)


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