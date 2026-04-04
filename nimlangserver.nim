import json_rpc/[servers/socketserver, private/jrpc_sys, jsonmarshal, rpcclient, router]
import chronicles, chronos
import std/[syncio, os, json, strutils, strformat]
import ls, suggestapi, utils, lstransports, asyncprocmonitor
import routes/[lsp, mcp]
import protocol/types
when defined(posix):
  import posix

proc registerMcpRoutes(srv: RpcSocketServer, ls: LanguageServer) =
  srv.register("initialize", wrapRpc(partial(mcp.initialize, (ls: ls, onExit: ls.onExit))))

proc registerLspRoutes(srv: RpcSocketServer, ls: LanguageServer) =
  srv.register("initialize", wrapRpc(partial(lsp.initialize, (ls: ls, onExit: ls.onExit))))
    #use from ls
  srv.register(
    "textDocument/completion", ls.addRpcToCancellable(wrapRpc(partial(lsp.completion, ls)))
  )
  srv.register(
    "textDocument/definition", ls.addRpcToCancellable(wrapRpc(partial(lsp.definition, ls)))
  )
  srv.register(
    "textDocument/declaration",
    ls.addRpcToCancellable(wrapRpc(partial(lsp.declaration, ls))),
  )
  srv.register(
    "textDocument/typeDefinition",
    ls.addRpcToCancellable(wrapRpc(partial(lsp.typeDefinition, ls))),
  )
  srv.register(
    "textDocument/documentSymbol",
    ls.addRpcToCancellable(wrapRpc(partial(lsp.documentSymbols, ls))),
  )
  srv.register(
    "textDocument/hover", ls.addRpcToCancellable(wrapRpc(partial(lsp.hover, ls)))
  )
  srv.register("textDocument/references", wrapRpc(partial(lsp.references, ls)))
  srv.register("textDocument/codeAction", wrapRpc(partial(lsp.codeAction, ls)))
  srv.register(
    "textDocument/prepareRename",
    ls.addRpcToCancellable(wrapRpc(partial(lsp.prepareRename, ls))),
  )
  srv.register(
    "textDocument/rename", ls.addRpcToCancellable(wrapRpc(partial(lsp.rename, ls)))
  )
  srv.register(
    "textDocument/inlayHint", ls.addRpcToCancellable(wrapRpc(partial(lsp.inlayHint, ls)))
  )
  srv.register(
    "textDocument/signatureHelp",
    ls.addRpcToCancellable(wrapRpc(partial(lsp.signatureHelp, ls))),
  )
  srv.register(
    "textDocument/formatting", ls.addRpcToCancellable(wrapRpc(partial(lsp.formatting, ls)))
  )
  srv.register("workspace/executeCommand", wrapRpc(partial(lsp.executeCommand, ls)))
  srv.register(
    "workspace/symbol", ls.addRpcToCancellable(wrapRpc(partial(lsp.workspaceSymbol, ls)))
  )
  srv.register(
    "textDocument/documentHighlight",
    ls.addRpcToCancellable(wrapRpc(partial(lsp.documentHighlight, ls))),
  )
  srv.register("shutdown", wrapRpc(partial(lsp.shutdown, ls)))
  srv.register("exit", wrapRpc(partial(lsp.exit, (ls: ls, onExit: ls.onExit))))
  #Extension
  srv.register("extension/macroExpand", wrapRpc(partial(lsp.expand, ls)))
  srv.register("extension/status", wrapRpc(partial(lsp.status, ls)))
  srv.register("extension/capabilities", wrapRpc(partial(lsp.extensionCapabilities, ls)))
  srv.register("extension/suggest", wrapRpc(partial(lsp.extensionSuggest, ls)))
  srv.register("extension/tasks", wrapRpc(partial(lsp.tasks, ls)))
  srv.register("extension/runTask", wrapRpc(partial(lsp.runTask, ls)))
  srv.register("extension/listTests", wrapRpc(partial(lsp.listTests, ls)))
  srv.register("extension/runTests", wrapRpc(partial(lsp.runTests, ls)))
  srv.register("extension/cancelTest", wrapRpc(partial(lsp.cancelTest, ls)))
  #Notifications
  srv.register("$/cancelRequest", wrapRpc(partial(lsp.cancelRequest, ls)))
  srv.register("initialized", wrapRpc(partial(lsp.initialized, ls)))
  srv.register("textDocument/didOpen", wrapRpc(partial(lsp.didOpen, ls)))
  srv.register("textDocument/didSave", wrapRpc(partial(lsp.didSave, ls)))
  srv.register("textDocument/didClose", wrapRpc(partial(lsp.didClose, ls)))
  srv.register(
    "workspace/didChangeConfiguration", wrapRpc(partial(lsp.didChangeConfiguration, ls))
  )
  srv.register("textDocument/didChange", wrapRpc(partial(lsp.didChange, ls)))
  srv.register(
    "textDocument/willSaveWaitUntil", wrapRpc(partial(lsp.willSaveWaitUntil, ls))
  )
  srv.register("$/setTrace", wrapRpc(partial(lsp.setTrace, ls)))

proc showHelp() =
  echo "nimlangserver: The Nim Language Server"
  echo "Version: ", LSPVersion
  echo ""
  echo "Options:"
  echo "  --help, -h               Show this help message"
  echo "  --version, -v            Show version information"
  echo "  --lsp                    Run in LSP server mode (default)"
  echo "  --mcp                    Run in MCP server mode"
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
    if param == "--lsp":
      result.mode = some ServerMode.lsp
    if param == "--mcp":
      result.mode = some ServerMode.mcp
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
  if result.mode.isNone:
    result.mode = some ServerMode.lsp
  if result.transport.isNone:
    result.transport = some TransportMode.stdio

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

  case result.serverMode
  of lsp:
    result.srv.registerLspRoutes(result)
  of mcp:
    result.srv.registerMcpRoutes(result)

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
