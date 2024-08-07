import macros, strformat, faststreams/async_backend,
  faststreams/asynctools_adapters, faststreams/inputs, faststreams/outputs,
  json_rpc/streamconnection, json_rpc/server, os, sugar, sequtils, hashes, osproc,
  suggestapi, protocol/enums, protocol/types, with, tables, strutils, sets,
  ./utils, ./pipes, chronicles, std/re, uri, "$nim/compiler/pathutils",
  asyncprocmonitor, std/strscans, json_serialization, serialization/formats,
  std/json, std/parseutils, ls, routes

when defined(posix):
  import posix


createJsonFlavor(LSPFlavour, omitOptionalFields = true)
Option.useDefaultSerializationIn LSPFlavour

proc partial*[A, B, C] (fn: proc(a: A, b: B): C {.gcsafe.}, a: A):
    proc (b: B) : C {.gcsafe, raises: [Defect, CatchableError, Exception].} =
  return
    proc(b: B): C {.gcsafe, raises: [Defect, CatchableError, Exception].} =
      return fn(a, b)

proc partial*[A, B, C] (fn: proc(a: A, b: B, id: int): C {.gcsafe.}, a: A):
    proc (b: B, id: int) : C {.gcsafe, raises: [Defect, CatchableError, Exception].} =
  return
    proc(b: B, id: int): C {.gcsafe, raises: [Defect, CatchableError, Exception].} =
      return fn(a, b, id)
  
# Fixes callback clobbering in core implementation
proc `or`*[T, Y](fut1: Future[T], fut2: Future[Y]): Future[void] =
  var retFuture = newFuture[void]("asyncdispatch.`or`")
  proc cb[X](fut: Future[X]) =
    if not retFuture.finished:
      if fut.failed: retFuture.fail(fut.error)
      else: retFuture.complete()
  fut1.addCallback(cb[T])
  fut2.addCallback(cb[Y])
  return retFuture

proc registerHandlers*(connection: StreamConnection,
                       pipeInput: AsyncInputStream,
                       storageDir: string,
                       cmdLineParams: CommandLineParams): LanguageServer =
  let onExit: OnExitCallback = proc () {.async.} = 
    pipeInput.close()
  
  let notifyAction: NotifyAction = proc(name: string, params: JsonNode) =
    connection.notify(name, params)

  let callAction: CallAction = proc(name: string, params: JsonNode): Future[JsonNode] =
    connection.call(name, params)

  let ls = LanguageServer(
    workspaceConfiguration: Future[JsonNode](),
    notify: notifyAction,
    call: callAction,
    projectFiles: initTable[string, Future[Nimsuggest]](),
    cancelFutures: initTable[int, Future[void]](),
    filesWithDiags: initHashSet[string](),
    openFiles: initTable[string, NlsFileInfo](),
    storageDir: storageDir,
    cmdLineClientProcessId: cmdLineParams.clientProcessId)
  result = ls


  connection.register("initialize", partial(initialize, (ls: ls, onExit: onExit)))
  connection.register("textDocument/completion", partial(completion, ls))
  connection.register("textDocument/definition", partial(definition, ls))
  connection.register("textDocument/declaration", partial(declaration, ls))
  connection.register("textDocument/typeDefinition", partial(typeDefinition, ls))
  connection.register("textDocument/documentSymbol", partial(documentSymbols, ls))
  connection.register("textDocument/hover", partial(hover, ls))
  connection.register("textDocument/references", partial(references, ls))
  connection.register("textDocument/codeAction", partial(codeAction, ls))
  connection.register("textDocument/prepareRename", partial(prepareRename, ls))
  connection.register("textDocument/rename", partial(rename, ls))
  connection.register("textDocument/inlayHint", partial(inlayHint, ls))
  connection.register("textDocument/signatureHelp", partial(signatureHelp, ls))
  connection.register("workspace/executeCommand", partial(executeCommand, ls))
  connection.register("workspace/symbol", partial(workspaceSymbol, ls))
  connection.register("textDocument/documentHighlight", partial(documentHighlight, ls))
  connection.register("extension/macroExpand", partial(expand, ls))
  connection.register("extension/status", partial(status, ls))
  connection.register("shutdown", partial(shutdown, ls))
  connection.register("exit", partial(exit, (ls: ls, onExit: onExit)))

  connection.registerNotification("$/cancelRequest", partial(cancelRequest, ls))
  connection.registerNotification("initialized", partial(initialized, ls))
  connection.registerNotification("textDocument/didChange", partial(didChange, ls))
  connection.registerNotification("textDocument/didOpen", partial(didOpen, ls))
  connection.registerNotification("textDocument/didSave", partial(didSave, ls))
  connection.registerNotification("textDocument/didClose", partial(didClose, ls))
  connection.registerNotification("workspace/didChangeConfiguration", partial(didChangeConfiguration, ls))
  connection.registerNotification("$/setTrace", partial(setTrace, ls))

proc ensureStorageDir*: string =
  result = getTempDir() / "nimlangserver"
  discard existsOrCreateDir(result)

var
  # global var, only used in the signal handlers (for stopping the child nimsuggest
  # processes during an abnormal program termination)
  globalLS: ptr LanguageServer

when isMainModule:

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

  proc main =
    try:
      let cmdLineParams = handleParams() 
      let storageDir = ensureStorageDir()
      var
        pipe = createPipe(register = true, nonBlockingWrite = false)
        stdioThread: Thread[tuple[pipe: AsyncPipe, file: File]]

      createThread(stdioThread, copyFileToPipe, (pipe: pipe, file: stdin))

      let
        connection = StreamConnection.new(Async(fileOutput(stdout, allowAsyncOps = true)))
        pipeInput = asyncPipeInput(pipe)
      var
        ls = registerHandlers(connection, pipeInput, storageDir, cmdLineParams)

      globalLS = addr ls

      if cmdLineParams.clientProcessId.isSome:
        debug "Registering monitor for process id, specified on command line", clientProcessId=cmdLineParams.clientProcessId.get

        proc onCmdLineClientProcessExitAsync(): Future[void] {.async.} =
          debug "onCmdLineClientProcessExitAsync"
          
          await ls.stopNimsuggestProcesses
          pipeInput.close()

        proc onCmdLineClientProcessExit(fd: AsyncFD): bool =
          debug "onCmdLineClientProcessExit"
          waitFor onCmdLineClientProcessExitAsync()
          result = true

        hookAsyncProcMonitor(cmdLineParams.clientProcessId.get, onCmdLineClientProcessExit)

      when defined(posix):
        onSignal(SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE):
          debug "Terminated via signal", sig
          globalLS.stopNimsuggestProcessesP()
          exitnow(1)

      waitFor connection.start(pipeInput)
      debug "exiting main thread", isShutdown=ls.isShutdown
      quit(if ls.isShutdown: 0 else: 1)
    except Exception as ex:
      debug "Shutting down due to an error: ", msg = ex.msg
      debug "Stack trace: ", stack_trace = ex.getStackTrace()
      stderr.writeLine("Shutting down due to an error: ", ex.msg)
      stderr.writeLine(ex.getStackTrace())
      quit 1

  main()
