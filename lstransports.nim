import json_rpc/[servers/socketserver, private/jrpc_sys, jsonmarshal, rpcclient, router]
import chronicles, chronos
import
  std/[
    syncio, os, json, jsonutils, strutils, strformat, streams, sequtils, sets, tables,
    oids,
  ]
import ls, routes, suggestapi, protocol/enums, utils
import protocol/types

template flavorUsesAutomaticObjectSerialization(T: type JrpcSys): bool =
  true

proc readValue*(r: var JsonReader, val: var OptionalNode) =
  try:
    discard r.tokKind()
    val = some r.parseJsonNode()
  except CatchableError:
    discard #None

proc writeValue*(w: var JsonWriter, value: OptionalNode) {.gcsafe, raises: [IOError].} =
  #We ignore none values
  if value.isSome:
    if w.hasPrettyOutput:
      write w.stream, value.get.pretty()
    else:
      write w.stream, $(value.get)

proc toJson*(params: RequestParamsRx): JsonNode =
  if params.kind == rpNamed:
    result = newJObject()
    for np in params.named:
      result[np.name] = parseJson($np.value)
  else:
    result = newJArray() #TODO this may be wrong
    for p in params.positional:
      result.add parseJson($p)

type LspClientResponse* = object
  jsonrpc*: JsonRPC2
  id*: string
  result*: JsonNode

proc processContentLength*(inputStream: FileStream): string =
  result = inputStream.readLine()
  if result.startsWith(CONTENT_LENGTH):
    let parts = result.split(" ")
    let length = parseInt(parts[1])
    discard inputStream.readLine() # skip the \r\n
    result = newString(length)
    for i in 0..<length:
      result[i] = inputStream.readChar()
  else:
    error "No content length \n"

proc processContentLength*(transport: StreamTransport): Future[string] {.async.} = 
  result = await transport.readLine()
  if result.startsWith(CONTENT_LENGTH):
    let parts = result.split(" ")
    let length = parseInt(parts[1])
    discard await transport.readLine() # skip the \r\n
    result = (await transport.read(length)).mapIt($(it.char)).join()

  else:
    error "No content length \n"
  


proc readStdin*(transport: StreamTransport) {.thread.} =  
  var inputStream = newFileStream(stdin)
  var value = processContentLength(inputStream)
  discard waitFor transport.write(value & CRLF)
  
  readStdin(transport)


proc writeOutput*(ls: LanguageServer, content: string) = 
  case ls.transportMode:
  of stdio:
    ls.outStream.write(content)
    ls.outStream.flush()
  of socket:
    discard waitFor ls.socketTransport.write(content)

proc startStdioLoop*(ls: LanguageServer, srv: RpcSocketServer): Future[void] {.async.} =
  debug "Starting stdio loop"
  #THIS IS BASICALLY A MOCKUP, has to be properly done
  #TODO outStream should be a StreamTransport
  {.cast(gcsafe).}:
    let content = await ls.rTranspStdin.readLine(sep = CRLF)
    let contentJson: JsonNode = parseJson(content)
    let isReq = "method" in contentJson
    try:
      if isReq:
        var fut = Future[JsonString]()
        var req = JrpcSys.decode(content, RequestRx)
        if req.params.kind == rpNamed and req.id.kind == riNumber:
          #Some requests have no id
          #We need to pass the id to the wrapRpc as the id information is lost in the rpc proc
          req.params.named.add ParamDescNamed(
            name: "idRequest", value: JsonString($(%req.id.num))
          )
        let routeResult = srv.router.tryRoute(req, fut)
        if routeResult.isOk:
          proc writeRequestResponse(arg: pointer) =
            try:
              let futur = cast[Future[JsonString]](arg)
              #TODO Refactor from here can be reused
              let res: JsonString = futur.read
              var json = newJObject()
              json["jsonrpc"] = %*"2.0"
              if req.id.kind == riNumber:
                json["id"] = %*req.id.num

              json["result"] = parseJson(res.string)
              let jsonStr = $json
              let responseStr = jsonStr
              let contentLenght = responseStr.len + 1
              let final = &"{CONTENT_LENGTH}{contentLenght}{CRLF}{CRLF}{responseStr}\n"
              ls.writeOutput(final)
            except CatchableError:
              error "[startStdioLoop] Writting Request Response ",
                msg = getCurrentExceptionMsg(), trace = getStackTrace()

          fut.addCallback(writeRequestResponse)
            #We dont await here to do not block the loop
        else:
          error "[startStdioLoop] routing request ", msg = $routeResult
      else: #Response
        let response = JrpcSys.decode(content, LspClientResponse)
        let id = response.id
        if response.result == nil:
          ls.responseMap[id].complete(newJObject())
        else:
          let r = response.result
          ls.responseMap[id].complete(r)
    except CatchableError:
      error "[startStdioLoop] ", msg = getCurrentExceptionMsg(), trace = getStackTrace()
    await startStdioLoop(ls, srv)

proc initActions*(ls: LanguageServer, srv: RpcSocketServer) = 
  let onExit: OnExitCallback = proc() {.async.} =
    case ls.transportMode:
    of stdio:
      ls.rTranspStdin.close()
      ls.wTranspStdin.close()
      ls.outStream.close()
    of socket:
      srv.stop() #TODO check if stop also close the transport, which it should
    
  let notifyAction: NotifyAction = proc(name: string, params: JsonNode) = #TODO notify action should be async
    try:
      stderr.write "notifyAction called\n"
      var json = newJObject()
      json["jsonrpc"] = %*"2.0"
      json["method"] = %*name
      json["params"] = params

      let jsonStr = $json
      let responseStr = jsonStr
      let contentLenght = responseStr.len + 1
      let final = &"{CONTENT_LENGTH}{contentLenght}{CRLF}{CRLF}{responseStr}\n"
      ls.writeOutput(final)
    except CatchableError:
      discard

  let callAction: CallAction = proc(name: string, params: JsonNode): Future[JsonNode]  =
    try:
      #TODO Refactor to unify the construction of the request
      debug "!!!!!!!!!!!!!!callAction called with ", name = name
      
      let id = $genOid()
      var json = newJObject()
      json["jsonrpc"] = %*"2.0"
      json["method"] = %*name
      json["id"] = %*id
      json["params"] = params

      let jsonStr = $json
      let responseStr = jsonStr
      let contentLenght = responseStr.len + 1
      let final = &"{CONTENT_LENGTH}{contentLenght}{CRLF}{CRLF}{responseStr}\n"
    
      ls.writeOutput(final)
      result = newFuture[JsonNode]()
      ls.responseMap[id] = result

    except CatchableError:      
      discard
  
  ls.call = callAction
  ls.notify = notifyAction
  ls.onExit = onExit

proc startStdioServer*(ls: LanguageServer, srv: RpcSocketServer) =
  #Holds the responses from the client done via the callAction. Likely this is only needed for stdio
  debug "Starting stdio server"
  #sets io streams
  let (rfd, wfd) = createAsyncPipe()
  ls.outStream = newFileStream(stdout)
  ls.rTranspStdin = fromPipe(rfd)
  ls.wTranspStdin = fromPipe(wfd)

  ls.initActions(srv)
  var stdioThread {.global.}: Thread[StreamTransport]

  createThread(stdioThread, readStdin, ls.wTranspStdin)
  asyncSpawn startStdioLoop(ls, srv)
  debug "Stdio server started"


#SOCKET "loop"
proc processClientHook*(ls: LanguageServer, server: StreamServer, transport: StreamTransport) {.async: (raises: []), gcsafe.} =
  try:
    var srv = getUserData[RpcSocketServer](server)
    ls.socketTransport = transport
    while true:
      var
        value = await processContentLength(transport)
      if value == "":
        error "Client disconnected"
        await transport.closeWait()
        break
      
      debug "Processing message ", address = transport.remoteAddress()#, line = value
      let contentJson = parseJson(value)
      let isReq = "method" in contentJson
      debug "Is request ", isReq = isReq
      if isReq:
        var req = JrpcSys.decode(value, RequestRx)
        if req.params.kind == rpNamed and req.id.kind == riNumber:
          #Some requests have no id
          #We need to pass the id to the wrapRpc as the id information is lost in the rpc proc
          req.params.named.add ParamDescNamed(
            name: "idRequest", value: JsonString($(%req.id.num))
          )
        let rpc = srv.router.procs.getOrDefault(req.meth.get)
        let resFut = rpc(req.params)
        proc writeRequestResponse(arg: pointer) =
          try:
            let futur = cast[Future[JsonString]](arg)
            #TODO Refactor from here can be reused
            if futur.error == nil:              
              let res: JsonString = futur.read
              var json = newJObject()
              json["jsonrpc"] = %*"2.0"
              if req.id.kind == riNumber:
                json["id"] = %*req.id.num

              json["result"] = parseJson(res.string)
              let jsonStr = $json
              let responseStr = jsonStr
              let contentLenght = responseStr.len + 1
              let final = &"{CONTENT_LENGTH}{contentLenght}{CRLF}{CRLF}{responseStr}\n"
              if transport != nil:                
                discard waitFor transport.write(final)
            else:
              debug "Future is erroing!"
              return
          except CatchableError:
            error "[processClient] Writting Request Response ",
              msg = getCurrentExceptionMsg(), trace = getStackTrace()
        resFut.addCallback(writeRequestResponse)
              
              
              # outStream.flush()
            # except CatchableError:
            #   error "[startStdioLoop] Writting Request Response ",
            #     msg = getCurrentExceptionMsg(), trace = getStackTrace()


          # fut.addCallback(writeRequestResponse)
            #We dont await here to do not block the loop
        # else:
        #   error "[startStdioLoop] routing request ", msg = $routeResult
      else: #Response
        let response = JrpcSys.decode(value, LspClientResponse)
        let id = response.id
        debug "*********** TODO PROCESS RESPONSE ************", id = id  
        # debug "Keys in responseMap", keys = responseMap.keys.toSeq
        if response.result == nil:
          ls.responseMap[id].complete(newJObject())
        else:          
          let r = response.result
          ls.responseMap[id].complete(r)

  except TransportError as ex:
    error "Transport closed during processing client", msg=ex.msg
  except CatchableError as ex:
    error "Error occured during processing client", msg=ex.msg
  except SerializationError as ex:
    error "Error occured during processing client", msg=ex.msg
