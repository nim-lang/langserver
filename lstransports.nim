import json_rpc/[servers/socketserver, private/jrpc_sys, jsonmarshal, rpcclient, router]
import chronicles, chronos
import
  std/[
    syncio, os, json, jsonutils, strutils, strformat, streams, sequtils, sets, tables,
    oids,
  ]
import ls, routes, suggestapi, protocol/enums, utils
import protocol/types

type LspClientResponse* = object
  jsonrpc*: JsonRPC2
  id*: string
  result*: JsonNode

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

type Rpc* = proc(params: RequestParamsRx): Future[JsonString] {.gcsafe, raises: [].}

proc wrapRpc*[T](
    fn: proc(params: T): Future[auto] {.gcsafe, raises: [].}
): Rpc =
  return proc(params: RequestParamsRx): Future[JsonString] {.gcsafe, async.} =
    var val = params.to(T)
    when typeof(fn(val)) is Future[void]: #Notification
      await fn(val)
      return JsonString("{}") #Client doesnt expect a response. Handled in processMessage
    else:
      let res = await fn(val)
      return JsonString($(%*res))

proc wrapRpc*[T](
    fn: proc(params: T, id: int): Future[auto] {.gcsafe, raises: [].}
): Rpc =
  return proc(params: RequestParamsRx): Future[JsonString] {.gcsafe, async.} =
    var val = params.to(T)
    var idRequest = 0
    try:
      idRequest = get[int](params, "idRequest")
      debug "IdRequest is ", idRequest = idRequest
    except KeyError:
      error "IdRequest not found in the request params"
    let res = await fn(val, idRequest)
    return JsonString($(%*res))

proc addRpcToCancellable*(ls: LanguageServer, rpc: Rpc): Rpc =
  return proc(params: RequestParamsRx): Future[JsonString] {.gcsafe, raises:[].} =
    try:
      var fut = rpc(params)
      let idRequest = get[int](params, "idRequest")
      ls.cancelableRequests[idRequest] = fut
      return fut
    except KeyError:
      error "IdRequest not found in the request params"
    except Exception:
      error "Error adding request to cancellable requests"


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

proc writeStackTrace*(ex = getCurrentException()) = 
  try:
    stderr.write ex.getStackTrace()
  except IOError:
    discard

proc writeOutput*(ls: LanguageServer, content: JsonNode) = 
  let responseStr = $content
  let contentLenght = responseStr.len + 1
  let res = &"{CONTENT_LENGTH}{contentLenght}{CRLF}{CRLF}{responseStr}\n"
  try:
    case ls.transportMode:
    of stdio:
      ls.outStream.write(res)
      ls.outStream.flush()
    of socket:
      discard waitFor ls.socketTransport.write(res)
  except CatchableError as ex:
    error "Error writing output", msg = ex.msg

proc runRpc(ls: LanguageServer, req: RequestRx, rpc: RpcProc): Future[void] {.async.} = 
  try:
    let res = await rpc(req.params)
    if res.string in ["", "{}"]:
      return  #Notification (see wrapRpc). The client doesnt expect a response
    var json = newJObject()
    json["jsonrpc"] = %*"2.0"
    if req.id.kind == riNumber:
      json["id"] = %*req.id.num
    json["result"] = parseJson(res.string)
    ls.writeOutput(json)
  except CatchableError as ex:
    error "[RunRPC] ", msg = ex.msg
    writeStackTrace(ex = ex)

proc processMessage(ls: LanguageServer, message: string) {.raises:[].} = 
  try:
    let contentJson = parseJson(message) #OPT oportunity reuse the same JSON already parsed
    let isReq = "method" in contentJson
    if isReq:
      debug "[Processsing Message]", request = contentJson["method"]
      var fut = Future[JsonString]()
      var req = JrpcSys.decode(message, RequestRx)
      if req.params.kind == rpNamed and req.id.kind == riNumber:
        #Some requests have no id but for others we need to pass the id to the wrapRpc as the id information is lost in the rpc proc
        req.params.named.add ParamDescNamed(name: "idRequest", value: JsonString($(%req.id.num)))
      let rpc = ls.srv.router.procs.getOrDefault(req.meth.get)
      if rpc.isNil:
        error "[Processsing Message] rpc method not found: ", msg = req.meth.get
        return
      asyncSpawn ls.runRpc(req, rpc)
    else: #Response
      let response = JrpcSys.decode(message, LspClientResponse)
      let id = response.id
      if response.result == nil:
        ls.responseMap[id].complete(newJObject())
        ls.responseMap.del id
      else:
        let r = response.result
        ls.responseMap[id].complete(r)
        ls.responseMap.del id

  except CatchableError:
    error "[Processsing Message] ", msg = getCurrentExceptionMsg(), trace = getStackTrace()

proc initActions*(ls: LanguageServer,) = 
  let onExit: OnExitCallback = proc() {.async.} =
    case ls.transportMode:
    of stdio:
      ls.rTranspStdin.close()
      ls.wTranspStdin.close()
      ls.outStream.close()
    of socket:
      ls.srv.stop() #TODO check if stop also close the transport, which it should
  
  template genJsonAction() {.dirty.} = 
    var json = newJObject()
    json["jsonrpc"] = %*"2.0"
    json["method"] = %*name
    json["params"] = params

  let notifyAction: NotifyAction = proc(name: string, params: JsonNode) =
      genJsonAction()
      ls.writeOutput(json)

  let callAction: CallAction = proc(name: string, params: JsonNode): Future[JsonNode]  =
    let id = $genOid()
    genJsonAction()
    json["id"] = %*id
    ls.writeOutput(json)
    result = newFuture[JsonNode]()
    #We store the future in the responseMap so we can complete it in processMessage
    ls.responseMap[id] = result 
  
  ls.call = callAction
  ls.notify = notifyAction
  ls.onExit = onExit

#start and loop functions belows are the only difference between transports
proc startStdioLoop*(ls: LanguageServer): Future[void] {.async.} =
  while true:
    let msg = await ls.rTranspStdin.readLine(sep = CRLF)
    debug "[Stdio Transport] Processing Message", msg = msg
    ls.processMessage(msg)

proc startStdioServer*(ls: LanguageServer) =
  #Holds the responses from the client done via the callAction. Likely this is only needed for stdio
  debug "Starting stdio server"
  #sets io streams
  let (rfd, wfd) = createAsyncPipe()
  ls.outStream = newFileStream(stdout)
  ls.rTranspStdin = fromPipe(rfd)
  ls.wTranspStdin = fromPipe(wfd)
  ls.srv = newRpcSocketServer()
  ls.initActions()
  var stdioThread {.global.}: Thread[StreamTransport]
  createThread(stdioThread, readStdin, ls.wTranspStdin)
  asyncSpawn ls.startStdioLoop()

proc processClientLoop*(ls: LanguageServer, server: StreamServer, transport: StreamTransport) {.async: (raises: []), gcsafe.} =
  ls.socketTransport = transport
  while true:
    let msg = await processContentLength(transport)
    if msg == "":
      error "Client disconnected"
      await transport.closeWait()
      break
    debug "[Socket Transport] Processing message ", address = transport.remoteAddress()
    ls.processMessage(msg)
  
proc startSocketServer*(ls: LanguageServer, port: Port) = 
    ls.srv = newRpcSocketServer(partial(processClientLoop, ls)) 
    ls.initActions()
    ls.srv.addStreamServer("localhost", port) 
    ls.srv.start()
    