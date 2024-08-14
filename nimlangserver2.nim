import json_rpc/[servers/socketserver, private/jrpc_sys, jsonmarshal, rpcclient, router]
import chronicles, chronos
import std/[syncio, os, json, jsonutils, strutils, strformat, streams, sequtils, sets, tables, oids]
import ls, routes, suggestapi, protocol/enums


import protocol/types


proc partial*[A, B, C] (fn: proc(a: A, b: B): C {.gcsafe, raises: [], nimcall.}, a: A): proc (b: B) : C {.gcsafe, raises: [].} =
  return
    proc(b: B): C {.gcsafe, raises: [].} =
      return fn(a, b)

proc partial*[A, B, C] (fn: proc(a: A, b: B, id: int): C {.gcsafe, raises: [], nimcall.}, a: A): proc (b: B, id: int) : C {.gcsafe, raises: [].} =
  return
    proc(b: B, id: int): C {.gcsafe, raises: [].} =
      debug "Partial with id inner called"
      return fn(a, b, id)


template flavorUsesAutomaticObjectSerialization(T: type JrpcConv): bool = true
template flavorUsesAutomaticObjectSerialization(T: type JrpcSys): bool = true

proc readValue*(r: var JsonReader, val: var OptionalNode) =
  try:
    discard r.tokKind()
    val = some r.parseJsonNode()
  except CatchableError:
    discard #None

type 
  LspClientResponse* = object
    jsonrpc*: JsonRPC2
    id*: string   
    result*: JsonNode

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

proc get[T](params: RequestParamsRx, key: string): T =
  if params.kind == rpNamed:
    for np in params.named:
      if np.name == key:
        return np.value.string.parseJson.to(T)
  raise newException(KeyError, "Key not found")

proc to*(params: RequestParamsRx, T: typedesc): T = 
  let value = $params.toJson()
  parseJson(value).to(T)
  
proc wrapRpc*[T](fn: proc(params: T): Future[auto] {.gcsafe, raises: [].}): proc(params: RequestParamsRx): Future[JsonString] {.gcsafe, raises: [].} =
  return proc(params: RequestParamsRx): Future[JsonString] {.gcsafe, async.}  =     
    var val = params.to(T)
    when typeof(fn(val)) is Future[void]: #Notification
      await fn(val)
      return JsonString("{}")
    else:
      let res = await fn(val)
      return JsonString($(%*res))

proc wrapRpc*[T](fn: proc(params: T, id: int): Future[auto] {.gcsafe, raises: [].}): proc(params: RequestParamsRx): Future[JsonString] {.gcsafe, raises: [].} =
  return proc(params: RequestParamsRx): Future[JsonString] {.gcsafe, async.}  =     
    var val = params.to(T)
    var idRequest = 0
    try:
      idRequest = params.get[:int]("idRequest")
      debug "IdRequest is ", idRequest = idRequest
    except KeyError:
      error "IdRequest not found in the request params"
    let res = await fn(val, idRequest)
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
    value = (inputStream.readStr(length)).mapIt($(it.char)).join()
    discard waitFor transport.write(value & "!END")
  else:
    stderr.write "No content length \n"
  readStdin(transport)



proc startStdioLoop*(outStream: FileStream, rTransp: StreamTransport, srv: RpcSocketServer, responseMap: TableRef[string, Future[JsonNode]]): Future[void] {.async.} =
  #THIS IS BASICALLY A MOCKUP, has to be properly done
  #TODO outStream should be a StreamTransport
  {.cast(gcsafe).}:
    let content = await rTransp.readLine(sep = "!END")
    let contentJson: JsonNode = parseJson(content)
    #Content can be a request or a response
    let isReq = "method" in contentJson
    # debug "Content received: ", isReq = isReq, content = content
    try:     
      if isReq:
        var fut = Future[JsonString]()
        var req = JrpcSys.decode(content, RequestRx)
        if req.params.kind == rpNamed and req.id.kind == riNumber: #Some requests have no id
          #We need to pass the id to the wrapRpc as the id information is lost in the rpc proc
          req.params.named.add ParamDescNamed(name: "idRequest", value: JsonString($(%req.id.num))) 
        let result2 =  srv.router.tryRoute(req, fut)
        debug "result2 for method: ", result2, meth = req.`method`
        if result2.isOk:
          let m  = req.`method`.get
          debug "open future", meth = m
          proc cb(arg: pointer) = 
            try:
              let futur = cast[Future[JsonString]](arg)
              let res = futur.read
              debug "After future"
              # if res.string == "{}": 
                #Notification, nothing to do here. 
                # return 
              var json =  newJObject()
              json["jsonrpc"] = %*"2.0"
              if req.id.kind == riNumber:
                json["id"] = %* req.id.num
              else:
                debug "Id is not a number", id = $req.id, meth = $req.`method`
              
              json["result"] = parseJson(res.string)
              let jsonStr = $json
              let responseStr = jsonStr
              let contentLenght = responseStr.len  + 1
              let final = &"{CONTENT_LENGTH}{contentLenght}{CRLF}{CRLF}{responseStr}\n"

              # debug "Sending response: ", final = final
              outStream.write(final)

              outStream.flush()
            except CatchableError:
              error "Error in startStdioLoop ", msg = getCurrentExceptionMsg(), trace = getStackTrace()
          
          fut.addCallback(cb) #We dont await here to do not block the loop
      else:
        let  response = JrpcSys.decode(content, LspClientResponse)
        let id = response.id
        debug "Response received", id = id
        if response.result == nil:
          debug "Fue niiiiillll"
          responseMap[id].complete(newJObject())
          debug "Completed future with empty object"
        else:
          debug "Response received", res = response.result
          
          let r = response.result  

          responseMap[id].complete(r)

          debug "Completed future with content ", r = $r
        

        # responseMap.del(id)
    except CatchableError:
      error "Error in startStdioLoop ", msg = getCurrentExceptionMsg(), trace = getStackTrace()    
    await startStdioLoop(outStream, rTransp, srv, responseMap)


proc main() = 

  debug "Starting nimlangserver"
  #[
  `nimlangserver` supports both transports: stdio and socket. By default it uses stdio transport. 
    But we do construct a RPC socket server even in stdio mode, so that we can reuse the same code for both transports.
    The server is not started when using stdio transport.
  ]#
  var responseMap: TableRef[system.string, Future[json.JsonNode]] = newTable[string, Future[JsonNode]]()
  var srv = newRpcSocketServer()
  #Holds the responses from the client done via the callAction. Likely this is only needed for stdio
  let outStream = newFileStream(stdout)
  let onExit: OnExitCallback = proc () {.async.} = 
    #TODO
    discard

  let notifyAction: NotifyAction = proc(name: string, params: JsonNode) =
    try:
      stderr.write "notifyAction called\n"
      var json =  newJObject()
      json["jsonrpc"] = %*"2.0"
      json["method"] = %*name
      json["params"] = params
      
      let jsonStr = $json
      let responseStr = jsonStr
      let contentLenght = responseStr.len  + 1
      let final = &"{CONTENT_LENGTH}{contentLenght}{CRLF}{CRLF}{responseStr}\n"
      outStream.write(final)
      outStream.flush()

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
  srv.register("textDocument/completion", wrapRpc(partial(completion, ls)))
  srv.register("textDocument/definition", wrapRpc(partial(definition, ls)))
  srv.register("textDocument/declaration", wrapRpc(partial(declaration, ls)))
  srv.register("textDocument/typeDefinition", wrapRpc(partial(typeDefinition, ls)))
  srv.register("textDocument/documentSymbol", wrapRpc(partial(documentSymbols, ls)))
  srv.register("textDocument/hover", wrapRpc(partial(hover, ls)))
  srv.register("textDocument/references", wrapRpc(partial(references, ls)))
  srv.register("textDocument/codeAction", wrapRpc(partial(codeAction, ls)))
  srv.register("textDocument/prepareRename", wrapRpc(partial(prepareRename, ls)))
  srv.register("textDocument/rename", wrapRpc(partial(rename, ls)))
  srv.register("textDocument/inlayHint", wrapRpc(partial(inlayHint, ls)))
  srv.register("textDocument/signatureHelp", wrapRpc(partial(signatureHelp, ls)))
  srv.register("workspace/executeCommand", wrapRpc(partial(executeCommand, ls)))
  srv.register("workspace/symbol", wrapRpc(partial(workspaceSymbol, ls)))
  srv.register("textDocument/documentHighlight", wrapRpc(partial(documentHighlight, ls)))
  srv.register("extension/macroExpand", wrapRpc(partial(expand, ls)))
  srv.register("extension/status", wrapRpc(partial(status, ls)))
  srv.register("shutdown", wrapRpc(partial(shutdown, ls)))
  # srv.register("exit", wrapRpc(partial(exit, (ls: ls, onExit: onExit))))
  


  #Notifications
  srv.register("$/cancelRequest", wrapRpc(partial(cancelRequest, ls)))
  srv.register("initialized", wrapRpc(partial(initialized, ls)))
  srv.register("textDocument/didOpen", wrapRpc(partial(didOpen, ls)))
  srv.register("textDocument/didSave", wrapRpc(partial(didSave, ls)))
  srv.register("textDocument/didClose", wrapRpc(partial(didClose, ls)))
  srv.register("workspace/didChangeConfiguration", wrapRpc(partial(didChangeConfiguration, ls)))
  srv.register("textDocument/didChange", wrapRpc(partial(didChange, ls)))
  srv.register("$/setTrace", wrapRpc(partial(setTrace, ls)))


  let (rfd, wfd) = createAsyncPipe()

  let
    rTransp = fromPipe(rfd)
    wTransp = fromPipe(wfd)

  var stdioThread: Thread[StreamTransport]
  createThread(stdioThread, readStdin, wTransp)

  asyncSpawn startStdioLoop(outStream, rTransp, srv, responseMap)

main()
runForever()