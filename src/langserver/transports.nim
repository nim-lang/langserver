import json_rpc/[servers/socketserver, private/jrpc_sys, jsonmarshal, rpcclient, router]
import chronicles, chronos
import std/[syncio, os, json, strutils, strformat, streams, oids, sequtils, times]
import ./[utils, langserver_types, messaging_types, constants, langserver]
import ../protocol/types
import chronos/threadsync

type
  LspClientResponse* = object
    jsonrpc*: JsonRPC2
    id*: string
    result*: JsonNode

  Rpc* = proc(params: RequestParamsRx): Future[JsonString] {.gcsafe, raises: [].}

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
    result = newJArray()
    for p in params.positional:
      result.add parseJson($p)

func withoutNulls(n: JsonNode): JsonNode =
  ## Return a JObject or JArray without any null nodes.
  ## If a JNull node is passed in, it is returned as is.

  doAssert n.kind in [JObject, JArray, JNull]

  case n.kind
  of JObject:
    result = newJObject()

    for k, v in n:
      case v.kind
      of JNull:
        discard
      of JObject, JArray:
        result[k] = v.withoutNulls
      else:
        result[k] = v
  of JArray:
    result = newJArray()

    for v in n:
      case v.kind
      of JNull:
        discard
      of JObject, JArray:
        result.add(v.withoutNulls)
      else:
        result.add(v)
  of JNull:
    result = newJNull()
  else:
    # This never happens because of the assertion above
    discard

proc wrapRpc*[T](fn: proc(params: T): Future[auto] {.gcsafe, raises: [].}): Rpc =
  return proc(params: RequestParamsRx): Future[JsonString] {.gcsafe, async.} =
    var val = params.to(T)
    when typeof(fn(val)) is Future[void]: #Notification
      await fn(val)
      return
        JsonString("{}") #Client doesnt expect a response. Handled in processMessage
    else:
      let res = await fn(val)
      return JsonString($((%*res).withoutNulls))

proc wrapRpc*[T](
    fn: proc(params: T, id: int): Future[auto] {.gcsafe, raises: [].}
): Rpc =
  return proc(params: RequestParamsRx): Future[JsonString] {.gcsafe, async.} =
    var val = params.to(T)
    var idRequest = 0
    try:
      idRequest = get[int](params, "idRequest")
    except KeyError:
      error "IdRequest not found in the request params", params = params
    let res = await fn(val, idRequest)
    return JsonString($((%*res).withoutNulls))

proc addRpcToCancellable*(ls: LanguageServer, rpc: Rpc): Rpc =
  return proc(params: RequestParamsRx): Future[JsonString] {.gcsafe, raises: [].} =
    try:
      let idRequest = get[uint](params, "idRequest")
      let name = get[string](params, "method")
      ls.messaging.pendingRequests[idRequest] =
        PendingRequest(id: idRequest, name: name, startTime: now(), state: prsOnGoing)
      ls.sendStatusChanged
      var fut = rpc(params)
      ls.messaging.pendingRequests[idRequest].request = fut
        #we need to add it before because the rpc may access to the pendingRequest to set the projectFile
      fut.addCallback proc(d: pointer) =
        try:
          ls.messaging.pendingRequests[idRequest].state = prsComplete
          ls.messaging.pendingRequests[idRequest].endTime = now()
          ls.sendStatusChanged
        except KeyError:
          error "Error completing pending requests. Id not found in pending requests"
      return fut
    except KeyError as ex:
      error "IdRequest not found in the request params"
      writeStackTrace(ex)
    except Exception as ex:
      error "Error adding request to cancellable requests"
      writeStackTrace(ex)

proc processContentLength*(inputStream: FileStream): string =
  try:
    result = inputStream.readLine()
    if result.startsWith(CONTENT_LENGTH):
      let parts = result.split(" ")
      let length = parseInt(parts[1])
      discard inputStream.readLine() # skip the \r\n
      result = newString(length)
      for i in 0 ..< length:
        result[i] = inputStream.readChar()
    else:
      error "No content length"
  except IOError as ex:
    error "Error reading content length from stdin", msg = ex.msg

proc processContentLength*(
    transport: StreamTransport, error: bool = true
): Future[string] {.async: (raises: []).} =
  try:
    result = await transport.readLine()
    if result.startsWith(CONTENT_LENGTH):
      let parts = result.split(" ")
      let length = parseInt(parts[1])
      discard await transport.readLine() # skip the \r\n
      result = (await transport.read(length)).mapIt($(it.char)).join()
    else:
      if error:
        error "No content length \n"
  except TransportError as ex:
    if error:
      error "Error reading content length", msg = ex.msg
  except CatchableError as ex:
    if error:
      error "Error reading content length", msg = ex.msg

proc readLspStdin*(ctx: ptr ReadStdinContext) {.thread.} =
  let inputStream = newFileStream(stdin)
  while true:
    let str = processContentLength(inputStream) & CRLF
    ctx.value = cast[cstring](createShared(char, str.len + 1))
    copymem(ctx.value[0].addr, str[0].addr, str.len)
    discard ctx.onStdReadSignal.fireSync()
    discard ctx.onMainReadSignal.waitSync()

proc readMcpStdin*(ctx: ptr ReadStdinContext) {.thread.} =
  let inputStream = newFileStream(stdin)
  while true:
    let str = inputStream.readLine()
    ctx.value = cast[cstring](createShared(char, str.len + 1))
    copymem(ctx.value[0].addr, str[0].addr, str.len)
    discard ctx.onStdReadSignal.fireSync()
    discard ctx.onMainReadSignal.waitSync()

proc wrapContentWithContentLength*(content: string): string =
  let contentLength = content.len + 1
  &"{CONTENT_LENGTH}{contentLength}{CRLF}{CRLF}{content}\n"

proc writeOutput*(ls: LanguageServer, content: JsonNode) =
  let res =
    case ls.capabilities.serverMode
    of lsp:
      wrapContentWithContentLength($content)
    of mcp:
      $content & "\n"

  try:
    case ls.transport.transportMode
    of stdio:
      # writing to a closed FILE is a SIGSEGV in libc, not a CatchableError
      if ls.transport.outStream.isNil:
        return
      ls.transport.outStream.write(res)
      ls.transport.outStream.flush()
    of socket:
      discard waitFor ls.transport.socketTransport.write(res)
  except CatchableError as ex:
    error "Error writing output", msg = ex.msg

proc runRpc(ls: LanguageServer, req: RequestRx, rpc: RpcProc): Future[void] {.async.} =
  try:
    let res = await rpc(req.params)
    if res.string in ["", "{}"]:
      return #Notification (see wrapRpc). The client doesnt expect a response
    var json = newJObject()
    json["jsonrpc"] = %*"2.0"
    if req.id.kind == riNumber:
      json["id"] = %*req.id.num
    json["result"] = parseJson(res.string)
    ls.writeOutput(json)
  except CancelledError as ex:
    debug "[RunRPC]Request cancelled", meth = req.meth
  except CatchableError as ex:
    error "[RunRPC] ", msg = ex.msg, req = req.`method`
    writeStackTrace(ex = ex)
    if req.id.kind == riNumber:
      ls.writeOutput(
        %*{
          "jsonrpc": "2.0",
          "id": req.id.num,
          "error": {"code": -32603, "message": ex.msg},
        }
      )

proc processLspMessages*(ls: LanguageServer): Future[void] {.async.} =
  ## Global thin-dispatcher coroutine. Dequeues LspDispatchItems and
  ## asyncSpawns each dispatch closure without awaiting its result.
  ##
  ## This is the bridge between the transport layer (which calls processMessage)
  ## and the handler layer (runRpc). It ensures that:
  ##   1. Message ordering is preserved — items are dispatched in arrival order.
  ##   2. Handlers run concurrently — no handler blocks the next dequeue.
  ##   3. The transport thread is never blocked by slow handlers.
  while true:
    let item = await ls.lspQueue.popFirst()
    asyncSpawn item.dispatch()

proc processMessage(ls: LanguageServer, message: string) {.raises: [].} =
  try:
    let contentJson = parseJson(message)
      #OPT oportunity reuse the same JSON already parsed
    let isReq = "method" in contentJson
    if isReq:
      debug "[Processing Message]", request = contentJson["method"]
      var fut = Future[JsonString]()
      var req = JrpcSys.decode(message, RequestRx)
      if req.params.kind == rpNamed and req.id.kind == riNumber:
        #Some requests have no id but for others we need to pass the id to the wrapRpc as the id information is lost in the rpc proc
        req.params.named.add ParamDescNamed(
          name: "idRequest", value: JsonString($(%req.id.num))
        )
        req.params.named.add ParamDescNamed(
          name: "method", value: JsonString($(contentJson["method"]))
        )
      let rpc = ls.transport.srv.router.procs.getOrDefault(req.meth.get)
      if rpc.isNil:
        error "[Processing Message] rpc method not found: ", msg = req.meth.get
        return
      let dispatchReq = req
      let dispatchRpc = rpc
      ls.lspQueue.addLastNoWait(LspDispatchItem(
        dispatch: proc(): Future[void] {.gcsafe, raises: [].} =
          ls.runRpc(dispatchReq, dispatchRpc)
      ))
    else: #Response
      let response = JrpcSys.decode(message, LspClientResponse)
      let id = response.id
      if id notin ls.messaging.responseMap:
        let callName = ls.messaging.responseNames.getOrDefault(id, "<unknown>")
        error "Id not found in responseMap", id = id, meth = callName
      else:
        let callFuture = ls.messaging.responseMap[id]
        ls.messaging.responseMap.del id
        ls.messaging.responseNames.del id
        if response.result == nil:
          callFuture.complete(newJObject())
        else:
          callFuture.complete(response.result)
  except JsonParsingError as ex:
    error "[Processing Message] Error parsing message", message = message
    writeStackTrace(ex)
  except CatchableError as ex:
    error "[Processing Message] "
    writeStackTrace(ex)

proc initActions*(ls: LanguageServer) =
  let onExit: OnExitCallback = proc() {.async.} =
    case ls.transport.transportMode
    of stdio:
      if not ls.transport.outStream.isNil:
        ls.transport.outStream.close()
        ls.transport.outStream = nil
      freeShared(ls.transport.stdinContext)
    of socket:
      ls.transport.srv.close()

  template genJsonAction() {.dirty.} =
    var json = newJObject()
    json["jsonrpc"] = %*"2.0"
    json["method"] = %*name
    json["params"] = params

  let notifyAction: NotifyAction = proc(name: string, params: JsonNode) =
    genJsonAction()
    ls.writeOutput(json.withoutNulls)

  let callAction: CallAction = proc(name: string, params: JsonNode): Future[JsonNode] =
    let id = $genOid()
    genJsonAction()
    json["id"] = %*id
    ls.writeOutput(json)
    result = newFuture[JsonNode]()
    #We store the future in the responseMap so we can complete it in processMessage
    ls.messaging.responseMap[id] = result
    ls.messaging.responseNames[id] = name

  ls.call = callAction
  ls.notify = notifyAction
  ls.onExit = onExit

#start and loop functions belows are the only difference between transports
proc startStdioLoop*(ls: LanguageServer): Future[void] {.async.} =
  while true:
    await ls.transport.stdinContext.onStdReadSignal.wait()
    let msg = $ls.transport.stdinContext.value
    freeShared(ls.transport.stdinContext.value[0].addr)
    await ls.transport.stdinContext.onMainReadSignal.fire()
    if msg == "":
      error "Client disconnected"
      break
    ls.processMessage(msg)

proc startStdioServer*(ls: LanguageServer) =
  #Holds the responses from the client done via the callAction. Likely this is only needed for stdio
  debug "Starting stdio server"
  ls.transport.srv = newRpcSocketServer()
  ls.initActions()
  ls.transport.outStream = newFileStream(stdout)
  var stdinThread {.global.}: Thread[ptr ReadStdinContext]
  ls.transport.stdinContext = createShared(ReadStdinContext)
  ls.transport.stdinContext.onMainReadSignal = ThreadSignalPtr.new().expect("")
  ls.transport.stdinContext.onStdReadSignal = ThreadSignalPtr.new().expect("")
  case ls.capabilities.serverMode
  of lsp:
    createThread(stdinThread, readLspStdin, ls.transport.stdinContext)
  of mcp:
    createThread(stdinThread, readMcpStdin, ls.transport.stdinContext)
  asyncSpawn ls.startStdioLoop()

proc processClientLoop*(
    ls: LanguageServer, server: StreamServer, transport: StreamTransport
) {.async: (raises: []), gcsafe.} =
  ls.transport.socketTransport = transport
  while true:
    let msg = await processContentLength(transport)
    if msg == "":
      error "Client disconnected"
      await transport.closeWait()
      break
    debug "[Socket Transport] Processing message ", address = transport.remoteAddress()
    ls.processMessage(msg)

proc startSocketServer*(ls: LanguageServer, port: Port) =
  ls.transport.srv = newRpcSocketServer(partial(processClientLoop, ls))
  ls.initActions()
  ls.transport.srv.addStreamServer("localhost", port)
  ls.transport.srv.start
  proc waitUntilSocketTransportIsReady(ls: LanguageServer) {.async.} =
    when defined(test):
      return
    while ls.transport.socketTransport.isNil:
      await sleepAsync(0)

  debug "Waiting for socket server to be ready"
  waitFor waitUntilSocketTransportIsReady(ls)
  debug "Socket server started"
