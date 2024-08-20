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

proc processContentLength*(transport: StreamTransport): Future[string] {.async:(raises:[]).} = 
  try:
    result = await transport.readLine()
    if result.startsWith(CONTENT_LENGTH):
      let parts = result.split(" ")
      let length = parseInt(parts[1])
      discard await transport.readLine() # skip the \r\n
      result = (await transport.read(length)).mapIt($(it.char)).join()

    else:
      error "No content length \n"
  except TransportError as ex:
    error "Error reading content length", msg = ex.msg
  except CatchableError as ex:
    error "Error reading content length", msg = ex.msg  


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

proc processMessage(ls: LanguageServer, srv: RpcSocketServer, message: string) {.raises:[].} = 
  try:
    let contentJson: JsonNode = parseJson(message)
    let isReq = "method" in contentJson
    if isReq:
      var fut = Future[JsonString]()
      var req = JrpcSys.decode(message, RequestRx)
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
              ls.writeOutput(final)
            else:
              debug "Future is erroing!" #TODO handle
              return
          except CatchableError:
            error "[Processsing Message] Writting Request Response ",
              msg = getCurrentExceptionMsg(), trace = getStackTrace()

        fut.addCallback(writeRequestResponse)
          #We dont await here to do not block the loop
      else:
        error "[Processsing Message] routing request ", msg = $routeResult
    else: #Response
      let response = JrpcSys.decode(message, LspClientResponse)
      let id = response.id
      if response.result == nil:
        ls.responseMap[id].complete(newJObject())
      else:
        let r = response.result
        ls.responseMap[id].complete(r)
  except CatchableError:
    error "[Processsing Message] ", msg = getCurrentExceptionMsg(), trace = getStackTrace()

proc startStdioLoop*(ls: LanguageServer, srv: RpcSocketServer): Future[void] {.async.} =
  debug "Starting stdio loop"
  let content = await ls.rTranspStdin.readLine(sep = CRLF)
  processMessage(ls, srv, content)
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
  var srv = getUserData[RpcSocketServer](server)
  ls.socketTransport = transport
  while true:
    let msg = await processContentLength(transport)
    if msg == "":
      error "Client disconnected"
      await transport.closeWait()
      break
    debug "Processing message ", address = transport.remoteAddress()
    processMessage(ls, srv, msg)
  
