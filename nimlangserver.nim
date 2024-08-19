import json_rpc/[servers/socketserver, private/jrpc_sys, jsonmarshal, rpcclient, router]
import chronicles, chronos
import
  std/[
    syncio, os, json, jsonutils, strutils, strformat, streams, sequtils, sets, tables,
    oids, sugar
  ]
import ls, routes, suggestapi, protocol/enums, utils, lstransports, asyncprocmonitor

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

proc initLs(tm: TransportMode): LanguageServer =
  LanguageServer(
    workspaceConfiguration: Future[JsonNode](),
    projectFiles: initTable[string, Future[Nimsuggest]](),
    cancelFutures: initTable[int, Future[void]](),
    filesWithDiags: initHashSet[string](),
    transportMode: tm,
    openFiles: initTable[string, NlsFileInfo](),
    responseMap: newTable[string, Future[JsonNode]]()
  )

proc initActions*(ls: LanguageServer, srv: RpcSocketServer) = 
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
      if ls.socketTransport != nil:
        debug "Writing to transport notification"
        discard waitFor ls.socketTransport.write(final)
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
        discard waitFor ls.socketTransport.write(final)
        result = newFuture[JsonNode]()
        ls.responseMap[id] = result

    except CatchableError:      
      discard
  
  ls.call = callAction
  ls.notify = notifyAction
  ls.onExit = onExit
  


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
  var ls = initLs(transportMode)
  var srv: RpcSocketServer
  
  case transportMode
  of stdio: 
    srv = newRpcSocketServer()
    ls = srv.startStdioServer()
    ls.storageDir = storageDir
    ls.cmdLineClientProcessId = cmdLineParams.clientProcessId  
  of socket:
    initActions(ls, srv)
    srv = newRpcSocketServer(partial(processClientHook, ls)) 
    srv.addStreamServer("localhost", Port(8888)) #TODO Param
    srv.start()
    


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
