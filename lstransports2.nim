## JSON-RPC transports for the language server: stdio and socket (TCP).
##
## Framing, routing, request/response correlation and error responses all come
## from `json_rpc`: the served connection becomes a bidirectional
## `RpcConnection` speaking the LSP `Content-Length` framing (see
## `stdioFraming` for the one exception), and incoming requests are dispatched
## through `ls.srv.router`. What is left here is the glue the language server
## needs on top of that:
##
## * `wrapRpc` adapts the handlers in `routes/` to `RpcProc`, since they take
##   the whole params object rather than one argument per member.
## * `route` dispatches each request off the read loop and records it, which
##   is what makes `$/cancelRequest` work.
## * `initActions` implements `ls.notify` / `ls.call` / `ls.onExit`.
##
## The two transports differ only in where the connection comes from: stdio
## serves the pipes the spawning client left on our own descriptors, the socket
## server serves every client that connects. `processStdioClient` and
## `processSocketClient` are the whole of that difference; the rest is shared.

{.push raises: [], gcsafe.}

import
  std/times,
  json_rpc/[
    servers/socketserver, clients/socketclient, servers/stdioserver, clients/stdioclient
  ],
  chronicles,
  chronos,
  stew/byteutils,
  ./protocol/[enums, types],
  ./[ls, utils]

logScope:
  topics = "lstransport"

type Rpc* = proc(params: RequestParamsRx): Future[JsonString] {.gcsafe, raises: [].}

func toJson(params: RequestParamsRx): string {.raises: [ValueError].} =
  if params.kind == rpPositional:
    if params.positional.len > 0:
      raise newException(ValueError, "Positional params are not supported")
    "{}"
  else:
    JrpcSys.encode(params.toTx)

func toParams(params: JsonString): Result[RequestParamsTx, string] =
  try:
    ok JrpcSys.decode(params, RequestParamsRx).toTx
  except CatchableError as ex:
    err ex.msg

proc wrapRpc*[T, F](fn: proc(params: T): F {.gcsafe, raises: [].}): Rpc =
  return proc(params: RequestParamsRx): Future[JsonString] {.async.} =
    let val =
      try:
        LspConv.decode(params.toJson, T, requireAllFields = true)
      except CatchableError as ex:
        raise (ref ApplicationError)(code: ord(InvalidParams), msg: ex.msg)
    try:
      when typeof(fn(val)) is Future[void]: #Notification
        await fn(val)
        return JsonString("null")
      else:
        let res = await fn(val)
        return JsonString(LspConv.encode(res))
    except CancelledError:
      raise
        (ref ApplicationError)(code: ord(RequestCancelled), msg: "Request cancelled")

proc trackRequest(
    ls: LanguageServer, request: RequestBatchRx, fut: FutureBase
) {.raises: [].} =
  ## Records an in-flight request so that `$/cancelRequest` can cancel it and
  ## the `extension/status` view can show what the server is busy with.
  if request.kind != rbkSingle:
    return
  let req = request.single
  let id = req.id.valueOr:
    return #A notification, there is nothing to cancel or report
  if id.kind != riNumber:
    return

  let reqId = id.num.uint
  ls.pendingRequests[reqId] = PendingRequest(
    id: reqId, name: req.meth, startTime: now(), state: prsOnGoing, request: fut
  )
  ls.sendStatusChanged

  #Which project the request is waiting on, for the status view
  if req.params.kind == rpNamed:
    for np in req.params.named:
      if np.name == "textDocument":
        try:
          let uri = LspConv.decode(np.value, TextDocumentIdentifier).uri
          asyncSpawn ls.addProjectFileToPendingRequest(reqId, uri)
        except CatchableError as ex:
          error "Cannot read the request textDocument", err = ex.msg
        break

  fut.addCallback proc(_: pointer) =
    try:
      ls.pendingRequests[reqId].state = prsComplete
      ls.pendingRequests[reqId].endTime = now()
      ls.sendStatusChanged
    except KeyError:
      error "Cannot complete the pending request, id not found", id = reqId

proc respond(
    ls: LanguageServer, conn: RpcConnection, handled: Future[seq[byte]].Raising([])
) {.async: (raises: []).} =
  let res =
    try:
      await handled
    except CancelledError:
      #`wrapRpc` turns a cancelled handler into a response, so this only
      #happens if the routing itself is cancelled
      return
  if res.len == 0: #A notification, the client expects no answer
    return
  try:
    await conn.send(res)
  except CancelledError:
    discard
  except JsonRpcError as ex:
    error "Cannot send response", err = ex.msg

proc route(
    ls: LanguageServer, conn: RpcConnection, request: RequestBatchRx
): Future[seq[byte]] {.async: (raises: [], raw: true).} =
  let handled = ls.srv.router.route(request)
  ls.trackRequest(request, handled)
  asyncSpawn ls.respond(conn, handled)

  result = Future[seq[byte]].Raising([]).init(
      "lstransport.route", {FutureFlag.OwnCancelSchedule}
    )
  result.complete(default(seq[byte]))

proc register(ls: LanguageServer, conn: RpcConnection) =
  ## Makes the connection *the* client: `ls.notify` and `ls.call` talk to
  ## whatever is registered here.
  ls.srv.connections.incl(conn)
  ls.connection = conn

proc unregister(ls: LanguageServer, conn: RpcConnection) =
  ls.srv.connections.excl(conn)
  if ls.connection == conn:
    ls.connection = nil

proc endServing(ls: LanguageServer, failure: ref JsonRpcError = nil) =
  if ls.served.isNil or ls.served.finished:
    return
  if failure.isNil:
    ls.served.complete()
  else:
    ls.served.fail(failure)

proc logDisconnect(conn: RpcConnection, address: string) =
  if conn.lastError.isNil:
    debug "Client disconnected", address = address
  else:
    warn "Client connection ended with an error",
      address = address, err = conn.lastError.msg

proc isConnected(conn: RpcConnection): bool =
  if conn.isNil:
    return false
  if conn of RpcSocketClient:
    let transport = RpcSocketClient(conn).transport
    return not transport.isNil and not transport.atEof()
  true

proc processSocketClient(
    ls: LanguageServer, server: StreamServer, transport: StreamTransport
) {.async: (raises: []).} =
  let remote = transport.remoteAddress2().valueOr(default(TransportAddress))

  if ls.connection.isConnected:
    warn "Refusing a second client, one is already connected", address = remote
    await transport.closeWait()
    return

  var conn: RpcSocketClient #Captured by the router, assigned right below
  conn = RpcSocketClient.new(
    framing = Framing.httpHeader(),
    router = proc(
        request: RequestBatchRx
    ): Future[seq[byte]] {.async: (raises: [], raw: true).} =
      ls.route(conn, request),
  )

  debug "Client connected", address = remote
  ls.register(conn)

  await conn.attach(transport, $remote)

  conn.logDisconnect($remote)
  ls.unregister(conn)

proc recvJsonLine(
    transport: StreamTransport, limit: int
): Future[seq[byte]] {.async: (raises: [CancelledError, TransportError]).} =
  toBytes(await transport.readLine(limit, sep = "\n"))

proc sendJsonLine(
    transport: StreamTransport, msg: seq[byte]
) {.async: (raises: [CancelledError, TransportError]).} =
  discard await transport.write(msg & toBytes("\n"))

# XXX MCP needs to be jsonLine in socket mode as well
proc stdioFraming(ls: LanguageServer): Framing =
  case ls.serverMode
  of lsp:
    Framing.httpHeader()
  of mcp:
    Framing.init(recvJsonLine, sendJsonLine)

proc processStdioClient(
    ls: LanguageServer, server: RpcStdioServer, input, output: StreamTransport
) {.async: (raises: []).} =
  var conn: RpcStdioClient
  conn = RpcStdioClient.new(
    framing = ls.stdioFraming(),
    router = proc(
        request: RequestBatchRx
    ): Future[seq[byte]] {.async: (raises: [], raw: true).} =
      ls.route(conn, request),
  )

  debug "Serving the client on stdio"
  ls.register(conn)

  await conn.attach(input, output, "stdio")

  conn.logDisconnect("stdio")
  ls.unregister(conn)
  ls.endServing(conn.lastError)

proc initActions*(ls: LanguageServer) =
  let onExit: OnExitCallback = proc() {.async: (raises: [IOError, OSError]).} =
    ls.endServing()
    case ls.transportMode
    of stdio:
      await RpcStdioServer(ls.srv).stop()
    of socket:
      RpcSocketServer(ls.srv).stop()
      RpcSocketServer(ls.srv).close()

  let notifyAction: NotifyAction = proc(name: string, params: JsonString) =
    let conn = ls.connection
    if conn.isNil:
      return
    let reqParams = params.toParams.valueOr:
      error "Cannot encode the notification params", name = name, err = error
      return

    proc send() {.async: (raises: []).} =
      try:
        await conn.notify(name, reqParams)
      except CancelledError:
        discard
      except JsonRpcError as ex:
        error "Cannot send notification", name = name, err = ex.msg

    asyncSpawn send()

  let callAction: CallAction = proc(
      name: string, params: JsonString
  ): Future[JsonNode].Raising([CancelledError, JsonRpcError]) =
    let fut = Future[JsonNode].Raising([CancelledError, JsonRpcError]).init("ls.call")
    let conn = ls.connection
    if conn.isNil:
      fut.fail newException(JsonRpcError, "No client connected")
      return fut
    let reqParams = params.toParams.valueOr:
      fut.fail newException(JsonRpcError, "Cannot encode the request params: " & error)
      return fut

    proc call() {.async: (raises: []).} =
      try:
        let res = await conn.call(name, reqParams)
        fut.complete(LspConv.decode(res, JsonNode))
      except CancelledError as ex:
        fut.fail ex
      except CatchableError as ex:
        error "Call to the client failed", name = name, err = ex.msg
        fut.fail newException(JsonRpcError, ex.msg)

    asyncSpawn call()
    fut

  ls.call = callAction
  ls.notify = notifyAction
  ls.onExit = onExit

proc serve*(ls: LanguageServer): Future[void] =
  ls.served

proc initServer*(ls: LanguageServer) =
  ls.served = newFuture[void]("ls.serve")
  ls.srv =
    case ls.transportMode
    of stdio:
      newRpcStdioServer(partial(processStdioClient, ls))
    of socket:
      newRpcSocketServer(partial(processSocketClient, ls))
  ls.initActions()

proc startStdioServer*(
    ls: LanguageServer, input, output: StreamTransport
) {.raises: [JsonRpcError].} =
  RpcStdioServer(ls.srv).start(input, output)
  debug "Stdio server started"

proc startStdioServer*(ls: LanguageServer) {.raises: [JsonRpcError].} =
  RpcStdioServer(ls.srv).start()
  debug "Stdio server started"

proc startSocketServer*(
    ls: LanguageServer, port: Port
) {.raises: [JsonRpcError, OSError, CancelledError].} =
  let srv = RpcSocketServer(ls.srv)
  srv.addStreamServer("localhost", port)
  srv.start()

  proc waitUntilConnected(ls: LanguageServer) {.async: (raises: [CancelledError]).} =
    while ls.connection.isNil:
      await sleepAsync(0)

  when not defined(test):
    #`ls.notify` and `ls.call` need a client to talk to
    debug "Waiting for socket server to be ready"
    waitFor waitUntilConnected(ls)
    debug "Socket server started"

proc startServer*(
    ls: LanguageServer, port: Port
) {.raises: [JsonRpcError, OSError, CancelledError].} =
  case ls.transportMode
  of stdio:
    ls.startStdioServer()
  of socket:
    ls.startSocketServer(port)
