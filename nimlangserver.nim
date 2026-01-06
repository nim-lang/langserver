import json_rpc/[servers/socketserver, private/jrpc_sys, jsonmarshal, rpcclient, router]
import chronicles, chronos
import std/[syncio, os, json, strutils, strformat]
import ls, routes, suggestapi, utils, lstransports, asyncprocmonitor
import protocol/types
when defined(posix):
  import posix

proc registerRoutes(srv: RpcSocketServer, ls: LanguageServer) =
  srv.register("initialize", wrapRpc(partial(initialize, (ls: ls, onExit: ls.onExit))))
    #use from ls
  srv.register(
    "textDocument/completion", ls.addRpcToCancellable(wrapRpc(partial(completion, ls)))
  )
  srv.register(
    "textDocument/definition", ls.addRpcToCancellable(wrapRpc(partial(definition, ls)))
  )
  srv.register(
    "textDocument/declaration",
    ls.addRpcToCancellable(wrapRpc(partial(declaration, ls))),
  )
  srv.register(
    "textDocument/typeDefinition",
    ls.addRpcToCancellable(wrapRpc(partial(typeDefinition, ls))),
  )
  srv.register(
    "textDocument/documentSymbol",
    ls.addRpcToCancellable(wrapRpc(partial(documentSymbols, ls))),
  )
  srv.register(
    "textDocument/hover", ls.addRpcToCancellable(wrapRpc(partial(hover, ls)))
  )
  srv.register("textDocument/references", wrapRpc(partial(references, ls)))
  srv.register("textDocument/codeAction", wrapRpc(partial(codeAction, ls)))
  srv.register(
    "textDocument/prepareRename",
    ls.addRpcToCancellable(wrapRpc(partial(prepareRename, ls))),
  )
  srv.register(
    "textDocument/rename", ls.addRpcToCancellable(wrapRpc(partial(rename, ls)))
  )
  srv.register(
    "textDocument/inlayHint", ls.addRpcToCancellable(wrapRpc(partial(inlayHint, ls)))
  )
  srv.register(
    "textDocument/signatureHelp",
    ls.addRpcToCancellable(wrapRpc(partial(signatureHelp, ls))),
  )
  srv.register(
    "textDocument/formatting", ls.addRpcToCancellable(wrapRpc(partial(formatting, ls)))
  )
  srv.register("workspace/executeCommand", wrapRpc(partial(executeCommand, ls)))
  srv.register(
    "workspace/symbol", ls.addRpcToCancellable(wrapRpc(partial(workspaceSymbol, ls)))
  )
  srv.register(
    "textDocument/documentHighlight",
    ls.addRpcToCancellable(wrapRpc(partial(documentHighlight, ls))),
  )
  srv.register("shutdown", wrapRpc(partial(shutdown, ls)))
  srv.register("exit", wrapRpc(partial(exit, (ls: ls, onExit: ls.onExit))))
  #Extension
  srv.register("extension/macroExpand", wrapRpc(partial(expand, ls)))
  srv.register("extension/status", wrapRpc(partial(status, ls)))
  srv.register("extension/capabilities", wrapRpc(partial(extensionCapabilities, ls)))
  srv.register("extension/suggest", wrapRpc(partial(extensionSuggest, ls)))
  srv.register("extension/tasks", wrapRpc(partial(tasks, ls)))
  srv.register("extension/runTask", wrapRpc(partial(runTask, ls)))
  srv.register("extension/listTests", wrapRpc(partial(listTests, ls)))
  srv.register("extension/runTests", wrapRpc(partial(runTests, ls)))
  srv.register("extension/cancelTest", wrapRpc(partial(cancelTest, ls)))
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
  srv.register(
    "textDocument/willSaveWaitUntil", wrapRpc(partial(willSaveWaitUntil, ls))
  )
  srv.register("$/setTrace", wrapRpc(partial(setTrace, ls)))

proc showHelp() =
  echo "nimlangserver: The Nim Language Server"
  echo "Version: ", LSPVersion
  echo ""
  echo "Options:"
  echo "  --help, -h               Show this help message"
  echo "  --version, -v            Show version information"
  echo "  --stdio                  Use stdio transport (default)"
  echo "  --socket                 Use socket transport"
  echo "  --port=<port>            Port to use for socket transport"
  echo "  --clientProcessId=<pid>  Exit when the given process ID terminates"
  echo ""
  const readme = staticRead("README.md")
  echo "CONFIGURATION OPTIONS"

  proc formatForConsole(md: string): string =
    var inCodeBlock = false
    result = ""
    for line in md.splitLines():
      if line.startsWith("```"):
        inCodeBlock = not inCodeBlock
        continue

      var cleaned = line
      if not inCodeBlock:
        cleaned = cleaned.multiReplace([("`", ""), ("\\", "")])

      if cleaned.len > 0:
        result.add(cleaned & "\n")

    result = result.strip()

  let section = readme.split("## Configuration Options")[1].split("##")[0]
  echo formatForConsole(section)
  quit(0)

proc handleParams(): CommandLineParams =
  if paramCount() > 0 and paramStr(1) in ["-v", "--version"]:
    echo LSPVersion
    quit()
  var i = 1
  while i <= paramCount():
    var param = paramStr(i)
    if param.startsWith("--clientProcessId="):
      var pidStr = param.substr(18)
      try:
        var pid = pidStr.parseInt
        result.clientProcessId = some(pid)
      except ValueError:
        stderr.writeLine("Invalid client process ID: ", pidStr)
        quit 1
    if param == "--stdio":
      result.transport = some TransportMode.stdio
    if param == "--socket":
      result.transport = some TransportMode.socket
    if param.startsWith "--port":
      let port = param.substr(7)
      try:
        result.port = Port(parseInt(port))
      except ValueError:
        error "Invalid port ", port = port
        quit(1)
    if param in ["help", "--help", "-h"]:
      showHelp()
    inc i
  if result.transport.isSome and result.transport.get == socket:
    if result.port == default(Port):
      result.port = getNextFreePort()
    echo &"port={result.port}"
  if result.transport.isNone:
    result.transport = some stdio

proc registerProcMonitor(ls: LanguageServer) =
  if ls.cmdLineClientProcessId.isSome:
    debug "Registering monitor for process id, specified on command line",
      clientProcessId = ls.cmdLineClientProcessId.get

    proc onCmdLineClientProcessExitAsync(): Future[void] {.async.} =
      debug "onCmdLineClientProcessExitAsync"

      await ls.stopNimsuggestProcesses
      waitFor ls.onExit()

    proc onCmdLineClientProcessExit() {.closure.} =
      debug "onCmdLineClientProcessExit"
      try:
        waitFor onCmdLineClientProcessExitAsync()
      except CatchableError as ex:
        error "Error in onCmdLineClientProcessExit"
        writeStackTrace(ex)

    hookAsyncProcMonitor(ls.cmdLineClientProcessId.get, onCmdLineClientProcessExit)

proc tickLs*(ls: LanguageServer, time = 1.seconds) {.async.} =
  await ls.tick()
  await sleepAsync(time)
  await ls.tickLs()

proc main*(cmdLineParams: CommandLineParams): LanguageServer =
  debug "Starting nimlangserver", version = LSPVersion, params = cmdLineParams
  #[
  `nimlangserver` supports both transports: stdio and socket. By default it uses stdio transport. 
    But we do construct a RPC socket server even in stdio mode, so that we can reuse the same code for both transports.
  ]#
  result = initLs(cmdLineParams, ensureStorageDir())
  case result.transportMode
  of stdio:
    result.startStdioServer()
  of socket:
    result.startSocketServer(cmdLineParams.port)

  result.srv.registerRoutes(result)
  result.registerProcMonitor()

when isMainModule:
  try:
    let ls = main(handleParams())
    asyncSpawn ls.tickLs()

    when defined(posix):
      onSignal(SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE):
        debug "Terminated via signal", sig
        ls.stopNimsuggestProcessesP()
        exitnow(1)
    runForever()
  except Exception as e:
    error "Error in main"
    writeStackTrace e
    quit(1)
