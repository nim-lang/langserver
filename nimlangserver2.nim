import json_rpc/[servers/socketserver, private/jrpc_sys, jsonmarshal, rpcclient, router]
import chronicles, chronos
import std/[syncio, os, json, jsonutils, strutils, strformat, streams, sequtils, sets, tables, oids]
import ls, routes, suggestapi, protocol/enums


import protocol/types

proc partial*[A, B, C] (fn: proc(a: A, b: B): C {.gcsafe, raises: [].}, a: A):
    proc (b: B) : C {.gcsafe, raises: [].} =
  return
    proc(b: B): C {.gcsafe, raises: [].} =
      return fn(a, b)


template flavorUsesAutomaticObjectSerialization(T: type JrpcConv): bool = true
template flavorUsesAutomaticObjectSerialization(T: type JrpcSys): bool = true

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
    

proc to*(params: RequestParamsRx, T: typedesc): T = 
  let value = $params.toJson()
  parseJson(value).to(T)
  
proc wrapRpc*[T](fn: proc(params: T): Future[auto] {.gcsafe, raises: [].}): proc(params: RequestParamsRx): Future[JsonString] {.gcsafe, raises: [].} =
  return proc(params: RequestParamsRx): Future[JsonString] {.gcsafe, async.}  =     
    var val = params.to(T)
    when typeof(fn(val)) is Future[void]:
      await fn(val)
      return JsonString("{}")
    else:
      let res = await fn(val)
      return JsonString($(%*res))


proc readStdin*(transport: StreamTransport) {.thread.} =
  var
    inputStream = newFileStream(stdin)  
  var
    value = inputStream.readLine()
  if "Content-Length:" in value: # HTTP header. TODO check only in the start of the string
    let parts = value.split(" ")
    let length = parseInt(parts[1])
    #TODO make this more efficient
    discard inputStream.readLine() # skip the \r\n
    value = (inputStream.readStr(length)).mapIt($(it.char)).join() & "!END"
    # debug "Read value: ", value = value
    discard waitFor transport.write(value)
  else:
    stderr.write "No content length \n"
  readStdin(transport)

proc startStdioLoop*(outStream: FileStream, rTransp: StreamTransport, srv: RpcSocketServer, responseMap: TableRef[string, Future[JsonNode]]): Future[void] {.async.} =
  #THIS IS BASICALLY A MOCKUP, has to be properly done
  #TODO outStream should be a StreamTransport
  {.cast(gcsafe).}:
    let content = await rTransp.readLine(sep = "!END")
    let req = JrpcSys.decode(content, RequestRx)
    var fut = Future[JsonString]()
    try:
      if req.`method`.isSome:
        let result2 =  srv.router.tryRoute(req, fut)
        debug "result2: ", result2
        let res = await fut
        var json =  newJObject()
        json["jsonrpc"] = %*"2.0"
        if req.id.kind == riNumber:
          json["id"] = %* req.id.num
        else:
          debug "Id is not a number", id = $req.id
        json["result"] = parseJson(res.string)
        let jsonStr = $json
        let responseStr = jsonStr
        let contentLenght = responseStr.len  + 1
        let final = &"{CONTENT_LENGTH}{contentLenght}{CRLF}{CRLF}{responseStr}\n"
    
        outStream.write(final)
        outStream.flush()
      else:
        debug "No method found. So the request is a response", reqId = req.id, req = $req
        #TODO check it's actually a str and not empty
        let id = req.id.str
        #TODO check pararms are ok
        let response = req.params.toJson()
        responseMap[id].complete(response)
    except CatchableError:
      error "Error in startStdioLoop ", msg = getCurrentExceptionMsg() 
    await startStdioLoop(outStream, rTransp, srv, responseMap)


proc main() = 

  debug "Starting nimlangserver"
  #[
  `nimlangserver` supports both transports: stdio and socket. By default it uses stdio transport. 
    But we do construct a RPC socket server even in stdio mode, so that we can reuse the same code for both transports.
    The server is not started when using stdio transport.
  ]#
  var srv = newRpcSocketServer()
  #Holds the responses from the client done via the callAction. Likely this is only needed for stdio
  var responseMap = newTable[string, Future[JsonNode]]()
  let outStream = newFileStream(stdout)
  let onExit: OnExitCallback = proc () {.async.} = 
    #TODO
    discard

  let notifyAction: NotifyAction = proc(name: string, params: JsonNode) =
    #TODO 
    try:
      stderr.write "notifyAction called\n"
    except CatchableError:
      discard

  let callAction: CallAction = proc(name: string, params: JsonNode): Future[JsonNode] =
    try:
      #TODO Refactor to unify the construction of the request
      debug "callAction called with ", name = name
      let id = $genOid()
      var json =  newJObject()
      json["jsonrpc"] = %*"2.0"
      json["method"] = %*name
      json["id"] = %*id
      json["params"] = params
      
      let jsonStr = $json
      let responseStr = jsonStr
      let contentLenght = responseStr.len  + 1
      let final = &"{CONTENT_LENGTH}{contentLenght}{CRLF}{CRLF}{responseStr}\n"
      outStream.write(final)
      outStream.flush()

      result = newFuture[JsonNode]()
      responseMap[id] = result


    except CatchableError:
      discard
    
  let ls = LanguageServer(
    workspaceConfiguration: Future[JsonNode](),
    notify: notifyAction,
    call: callAction,
    projectFiles: initTable[string, Future[Nimsuggest]](),
    cancelFutures: initTable[int, Future[void]](),
    filesWithDiags: initHashSet[string](),
    openFiles: initTable[string, NlsFileInfo]())
    # storageDir: storageDir,
    # cmdLineClientProcessId: cmdLineParams.clientProcessId)

  srv.register("initialize", wrapRpc(partial(initialize, (ls: ls, onExit: onExit))))
  

  #Notifications
  srv.register("initialized", wrapRpc(partial(initialized, ls)))
  srv.rpc("textDocument/didOpen") do(params: JsonNode) -> JsonNode:
    debug "fake textDocument/didOpen called"
    ls.showMessage(fmt """Notification test.""", MessageType.Info)

    newJObject()
  srv.rpc("$/setTrace") do(params: JsonNode) -> JsonNode:
    debug "fake setTrace called"
    newJObject()

  let (rfd, wfd) = createAsyncPipe()

  let
    rTransp = fromPipe(rfd)
    wTransp = fromPipe(wfd)

  var stdioThread: Thread[StreamTransport]
  createThread(stdioThread, readStdin, wTransp)

  asyncSpawn startStdioLoop(outStream, rTransp, srv, responseMap)

main()
runForever()