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

proc readStdin*(transport: StreamTransport) {.thread.} =
  var inputStream = newFileStream(stdin)
  var value = inputStream.readLine()
  if "Content-Length:" in value:
    # HTTP header. TODO check only in the start of the string
    let parts = value.split(" ")
    let length = parseInt(parts[1])
    #TODO make this more efficient
    discard inputStream.readLine() # skip the \r\n
    value = (inputStream.readStr(length)).mapIt($(it.char)).join()
    discard waitFor transport.write(value & "!END")
  else:
    stderr.write "No content length \n"
  readStdin(transport)

proc startStdioLoop*(
    outStream: FileStream,
    rTransp: StreamTransport,
    srv: RpcSocketServer,
    responseMap: TableRef[string, Future[JsonNode]],
): Future[void] {.async.} =
  #THIS IS BASICALLY A MOCKUP, has to be properly done
  #TODO outStream should be a StreamTransport
  {.cast(gcsafe).}:
    let content = await rTransp.readLine(sep = "!END")
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

              outStream.write(final)
              outStream.flush()
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
          responseMap[id].complete(newJObject())
        else:
          let r = response.result
          responseMap[id].complete(r)
    except CatchableError:
      error "[startStdioLoop] ", msg = getCurrentExceptionMsg(), trace = getStackTrace()
    await startStdioLoop(outStream, rTransp, srv, responseMap)
