import json_rpc/[servers/socketserver, private/jrpc_sys, jsonmarshal, rpcclient, router]
import chronicles, chronos
import
  std/[
    syncio, os, json, jsonutils, strutils, strformat, streams, sequtils, sets, tables,
    oids, sugar
  ]
import ls, routes, suggestapi, protocol/enums, utils, stdiotransport, asyncprocmonitor

import protocol/types
when defined(posix):
  import posix

proc registerRoutes(srv: RpcSocketServer, ls: LanguageServer, onExit: OnExitCallback) =
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
  srv.register(
    "textDocument/documentHighlight", wrapRpc(partial(documentHighlight, ls))
  )
  srv.register("extension/macroExpand", wrapRpc(partial(expand, ls)))
  srv.register("extension/status", wrapRpc(partial(status, ls)))
  srv.register("shutdown", wrapRpc(partial(shutdown, ls)))
  srv.register("exit", wrapRpc(partial(exit, (ls: ls, onExit: onExit))))

  #Notifications
  srv.register("$/cancelRequest", wrapRpc(partial(cancelRequest, ls)))
  srv.register("initialized", wrapRpc(partial(initialized, ls)))
  srv.register("textDocument/didOpen", wrapRpc(partial(didOpen, ls)))
  srv.register("textDocument/didSave", wrapRpc(partial(didSave, ls)))
  srv.register("textDocument/didClose", wrapRpc(partial(didClose, ls)))
  srv.register(
    "workspace/didChangeConfiguration", wrapRpc(partial(didChangeConfiguration, ls))
  )
  srv.register("textDocument/didChange", wrapRpc(partial(didChange, ls)))
  srv.register("$/setTrace", wrapRpc(partial(setTrace, ls)))
  

proc handleParams(): CommandLineParams =
  if paramCount() > 0 and paramStr(1) in ["-v", "--version"]:
    echo LSPVersion
    quit()
  var i = 1
  while i <= paramCount():
    var para = paramStr(i)
    if para.startsWith("--clientProcessId="):
      var pidStr = para.substr(18)
      try:
        var pid = pidStr.parseInt
        result.clientProcessId = some(pid)
      except ValueError:
        stderr.writeLine("Invalid client process ID: ", pidStr)
        quit 1
    inc i

var
  # global var, only used in the signal handlers (for stopping the child nimsuggest
  # processes during an abnormal program termination)
  globalLS: ptr LanguageServer

var socketTransport: StreamTransport #Store it inside the lsp. Notice that for
var responseMap = newTable[string, Future[JsonNode]]()
# waitFor client.connect("localhost", Port(8889))
proc processClientHook(server: StreamServer, transport: StreamTransport) {.async: (raises: []), gcsafe.} =
  try:
    var srv = getUserData[RpcSocketServer](server)
    {.cast(gcsafe).}:
      socketTransport = transport
    while true:
      var
        value = await transport.readLine(router.defaultMaxRequestLength)

      if "Content-Length:" in value: # HTTP header. TODO check only in the start of the string
        let parts = value.split(" ")
        let length = parseInt(parts[1])
        #TODO make this more efficient
        # value = (await transport.read(length)).mapIt($(it.char)).join()
        discard await transport.readLine() # skip the \r\n
        value = (await transport.read(length)).mapIt($(it.char)).join()
        # echo "************** REQUEST ******************* "
        # echo value
        # echo "************** END *******************"
        

      if value == "":
        echo "Client disconnected"
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
        {.cast(gcsafe).}:
          # debug "Keys in responseMap", keys = responseMap.keys.toSeq
          if response.result == nil:
            debug "Content is nil"
            responseMap[id].complete(newJObject())
          else:
            debug "Content is ", res = response.result          
            
            let r = response.result
            responseMap[id].complete(r)

  except TransportError as ex:
    error "Transport closed during processing client", msg=ex.msg
  except CatchableError as ex:
    error "Error occured during processing client", msg=ex.msg
  except SerializationError as ex:
    error "Error occured during processing client", msg=ex.msg

proc startSocketServer*(srv: RpcSocketServer, transport: StreamTransport): LanguageServer = 
  let onExit: OnExitCallback = proc() {.async.} =
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
      {.cast(gcsafe).}:

        if socketTransport != nil:
          debug "Writing to transport notification"
          discard waitFor socketTransport.write(final)
        else:
          error "Transport is nil in notifyAction"
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
      {.cast(gcsafe).}:
        discard waitFor socketTransport.write(final)
        result = newFuture[JsonNode]()
        responseMap[id] = result

    except CatchableError:      
      discard
  
  result = LanguageServer(
    workspaceConfiguration: Future[JsonNode](),
    notify: notifyAction,
    call: callAction,
    onExit: onExit,
    projectFiles: initTable[string, Future[Nimsuggest]](),
    cancelFutures: initTable[int, Future[void]](),
    filesWithDiags: initHashSet[string](),
    transportMode: stdio,
    openFiles: initTable[string, NlsFileInfo]()    
  )
  srv.addStreamServer("localhost", Port(8888)) #TODO Param
  srv.start()

proc main() =
  let cmdLineParams = handleParams()
  let storageDir = ensureStorageDir()
  debug "Starting nimlangserver", params = commandLineParams()
  #TODO handle transport in handleParams
  let transportMode = parseEnum[TransportMode](
    commandLineParams().filterIt("stdio" in it).head.map(it => it.replace("--", "")).get("socket")
  )
  debug "Transport mode is ", transportMode = transportMode
  #[
  `nimlangserver` supports both transports: stdio and socket. By default it uses stdio transport. 
    But we do construct a RPC socket server even in stdio mode, so that we can reuse the same code for both transports.
    The server is not started when using stdio transport.
  ]#
  var srv = newRpcSocketServer(processClientHook) #Note processClient hook will only be called in socket mode. 
  var ls: LanguageServer
  case transportMode
  of stdio: 
    var ls = srv.startStdioServer()
    ls.storageDir = storageDir
    ls.cmdLineClientProcessId = cmdLineParams.clientProcessId  
  of socket:
    ls = srv.startSocketServer(socketTransport)
    


  globalLS = addr ls
  srv.registerRoutes(ls, ls.onExit) #TODO use the onExit from the ls directly

  #TODO move to a function
  if cmdLineParams.clientProcessId.isSome:
    debug "Registering monitor for process id, specified on command line",
      clientProcessId = cmdLineParams.clientProcessId.get

    proc onCmdLineClientProcessExitAsync(): Future[void] {.async.} =
      debug "onCmdLineClientProcessExitAsync"

      await ls.stopNimsuggestProcesses
      waitFor ls.onExit()

    proc onCmdLineClientProcessExit() {.closure.} =
      debug "onCmdLineClientProcessExit"
      try:
        waitFor onCmdLineClientProcessExitAsync()
      except CatchableError:
        error "Error in onCmdLineClientProcessExit",
          msg = getCurrentExceptionMsg(), trace = getStackTrace()

    hookAsyncProcMonitor(cmdLineParams.clientProcessId.get, onCmdLineClientProcessExit)

  when defined(posix):
    onSignal(SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE):
      debug "Terminated via signal", sig
      globalLS.stopNimsuggestProcessesP()
      exitnow(1)
  
  runForever()

main()

