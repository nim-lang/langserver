import json_rpc/[servers/socketserver, /private/jrpc_sys, jsonmarshal, rpcclient, router]
import chronicles, chronos
import std/[syncio, os, json, jsonutils, strutils, strformat, streams, sequtils, sets, tables]
import ls, routes, suggestapi


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
  result = newJObject()
  assert params.kind == rpNamed
  for np in params.named:
    result[np.name] = parseJson($np.value)

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
    discard waitFor transport.write(value)
  else:
    stderr.write "No content length \n"
  readStdin(transport)

proc startStdioLoop*(outStream: FileStream, rTransp: StreamTransport, srv: RpcSocketServer): Future[void] {.async.} =
  #THIS IS BASICALLY A MOCKUP, has to be properly done
  #TODO outStream should be a StreamTransport
  {.cast(gcsafe).}:
    let content = await rTransp.readLine(sep = "!END")
    let req = JrpcSys.decode(content, RequestRx)
    var fut = Future[JsonString]()

    let result2 =  srv.router.tryRoute(req, fut)
    let res = await fut
    var json =  newJObject()
    json["jsonrpc"] = %*"2.0"
    if req.id.kind == riNumber:
      json["id"] = %* req.id.num
    json["result"] = parseJson(res.string)
    let jsonStr = $json
    let responseStr = jsonStr
    let contentLenght = responseStr.len  + 1
    let final = &"{CONTENT_LENGTH}{contentLenght}{CRLF}{CRLF}{responseStr}\n"
   
    outStream.write(final)
    outStream.flush()
    await startStdioLoop(outStream, rTransp, srv)


proc main() = 

  debug "Starting nimlangserver"
  #[
  `nimlangserver` supports both transports: stdio and socket. By default it uses stdio transport. 
    But we do construct a RPC socket server even in stdio mode, so that we can reuse the same code for both transports.
    The server is not started when using stdio transport.
  ]#
  var srv = newRpcSocketServer()
  let onExit: OnExitCallback = proc () {.async.} = 
    #TODO
    discard

  let notifyAction: NotifyAction = proc(name: string, params: JsonNode) =
    #TODO 
    discard

  let callAction: CallAction = proc(name: string, params: JsonNode): Future[JsonNode] =
    discard #TODO

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
  

  let (rfd, wfd) = createAsyncPipe()

  let
    rTransp = fromPipe(rfd)
    wTransp = fromPipe(wfd)

  var stdioThread: Thread[StreamTransport]
  createThread(stdioThread, readStdin, wTransp)

  asyncSpawn startStdioLoop(newFileStream(stdout), rTransp, srv)

main()
runForever()