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
  srv.register("textDocument/completion", ls.addRpcToCancellable(wrapRpc(partial(completion, ls))))
  srv.register("textDocument/definition", ls.addRpcToCancellable(wrapRpc(partial(definition, ls))))
  srv.register("textDocument/declaration", ls.addRpcToCancellable(wrapRpc(partial(declaration, ls))))
  srv.register("textDocument/typeDefinition", ls.addRpcToCancellable(wrapRpc(partial(typeDefinition, ls))))
  srv.register("textDocument/documentSymbol", ls.addRpcToCancellable(wrapRpc(partial(documentSymbols, ls))))
  srv.register("textDocument/hover", ls.addRpcToCancellable(wrapRpc(partial(hover, ls))))
  srv.register("textDocument/references", wrapRpc(partial(references, ls)))
  srv.register("textDocument/codeAction", wrapRpc(partial(codeAction, ls)))
  srv.register("textDocument/prepareRename", ls.addRpcToCancellable(wrapRpc(partial(prepareRename, ls))))
  srv.register("textDocument/rename", ls.addRpcToCancellable(wrapRpc(partial(rename, ls))))
  srv.register("textDocument/inlayHint", ls.addRpcToCancellable(wrapRpc(partial(inlayHint, ls))))
  srv.register("textDocument/signatureHelp", ls.addRpcToCancellable(wrapRpc(partial(signatureHelp, ls))))
  srv.register("workspace/executeCommand", wrapRpc(partial(executeCommand, ls)))
  srv.register("workspace/symbol", ls.addRpcToCancellable(wrapRpc(partial(workspaceSymbol, ls))))
  srv.register(
    "textDocument/documentHighlight", ls.addRpcToCancellable(wrapRpc(partial(documentHighlight, ls)))
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




  


proc main() =
  let cmdLineParams = handleParams()
  let storageDir = ensureStorageDir()
  debug "Starting nimlangserver", params = commandLineParams()
  #TODO properly handle transport in handleParams
  let transportMode = parseEnum[TransportMode](
    commandLineParams().filterIt("stdio" in it or "socket" in it).head.map(it => it.replace("--", "")).get("stdio")
  )
  debug "Transport mode is ", transportMode = transportMode
  #[
  `nimlangserver` supports both transports: stdio and socket. By default it uses stdio transport. 
    But we do construct a RPC socket server even in stdio mode, so that we can reuse the same code for both transports.
  ]#
  var ls = initLs(transportMode)
  ls.storageDir = storageDir
  ls.cmdLineClientProcessId = cmdLineParams.clientProcessId  
  case transportMode
  of stdio: 
    ls.startStdioServer()
  of socket:
    ls.startSocketServer(Port(8888))

  globalLS = addr ls #TODO use partial instead
  ls.srv.registerRoutes(ls, ls.onExit) #TODO use the onExit from the ls directly

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
try:
  main()
except Exception as e:
  error "Error in main", msg = e.msg, trace = getStackTrace()
  quit(1)
