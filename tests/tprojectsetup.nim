
#setup a new nimble project
import std/[unittest, osproc, os, sequtils, sugar, strutils]
import
  ../nimlangserver,
  ../protocol/types,
  ../utils,
  faststreams/async_backend,
  faststreams/asynctools_adapters,
  json_rpc/jsonmarshal,
  json_rpc/streamconnection,
  chronicles,
  std/json,
  strformat,
  sugar,
  unittest

template cd*(dir: string, body: untyped) =
  ## Sets the current dir to ``dir``, executes ``body`` and restores the
  ## previous working dir.
  let lastDir = getCurrentDir()
  setCurrentDir(dir)
  block:
    defer: setCurrentDir(lastDir)
    body

template createNewDir*(dir: string) =
  removeDir dir
  createDir dir

template cdNewDir*(dir: string, body: untyped) =
  createNewDir dir
  cd dir:
    body


let
  rootDir = getCurrentDir()
  nimblePath* = findExe "nimble"
  installDir* = rootDir / "tests" / "nimbleDir"

type
  ProcessOutput* = tuple[output: string, exitCode: int]


proc execNimble*(args: varargs[string]): ProcessOutput =
  var quotedArgs = @args
  if not args.anyIt("--nimbleDir:" in it or "-l"  == it or "--local" == it):
    quotedArgs.insert("--nimbleDir:" & installDir)
  quotedArgs.insert(nimblePath)
  quotedArgs = quotedArgs.map((x: string) => x.quoteShell)

  let path {.used.} = getCurrentDir().parentDir() / "src"

  var cmd =
    when not defined(windows):
      "PATH=" & path & ":$PATH " & quotedArgs.join(" ")
    else:
      quotedArgs.join(" ")
  when defined(macosx):
    # TODO: Yeah, this is really specific to my machine but for my own sanity...
    cmd = "DYLD_LIBRARY_PATH=/usr/local/opt/openssl@1.1/lib " & cmd

  result = execCmdEx(cmd)
  checkpoint(cmd)
  checkpoint(result.output)

proc execNimbleYes*(args: varargs[string]): ProcessOutput =
  execNimble(@args & "-y")

#TODO extract testutils and reusue this functions in both, tnimlangserver and this file

var notificationOutputs = newJArray()

proc registerHandlers*(connection: StreamConnection,
                       pipeInput: AsyncInputStream,
                       storageDir: string): LanguageServer =
  registerHandlers(connection, pipeInput, storageDir, CommandLineParams())

proc testHandler[T, Q](input: tuple[fut: FutureStream[T], res: Q], arg: T):
    Future[Q] {.async, gcsafe.} =
  debug "Received call: ", arg = %arg
  discard input.fut.write(arg)
  return input.res

proc testHandler[T](fut: FutureStream[T], arg: T): Future[void] {.async, gcsafe.} =
  debug "Received notification: ", arg = %arg
  {.cast(gcsafe).}:
    notificationOutputs.add %arg
  discard fut.write(arg)

proc fixtureUri(path: string): string =
  result = pathToUri(getCurrentDir() / "tests" / path)

proc createDidOpenParams(file: string): DidOpenTextDocumentParams =
  return DidOpenTextDocumentParams %* {
    "textDocument": {
      "uri": pathToUri(file),
      "languageId": "nim",
      "version": 0,
      "text": readFile(file)
     }
  }

proc createNimbleProject(projectDir: string) = 
  cdNewDir projectDir:     
    let (output, exitCode) = execNimbleYes("init")
    check exitCode == 0

type NimLangServerConnection* = ref object of RootObj
  client: StreamConnection
  server: StreamConnection
  suggestInit: FutureStream[ProgressParams]
  pipeServer: AsyncPipe
  pipeClient: AsyncPipe
  inputPipe: AsyncInputStream
  configInit: FutureStream[ConfigurationParams]
  diagnostics: FutureStream[PublishDiagnosticsParams]
  progress: FutureStream[ProgressParams]
  showMessage: FutureStream[ShowMessageParams]
  storageDir: string



proc initLangServerConnect(workspaceConfiguration: JsonNode): NimLangServerConnection  = 
  result = NimLangServerConnection.new()
  result.pipeServer = createPipe()
  result.pipeClient = createPipe()
  result.inputPipe = asyncPipeInput(result.pipeClient)
  result.storageDir = ensureStorageDir()
  result.server = StreamConnection.new(createPipe())
  discard registerHandlers(result.server, result.inputPipe, result.storageDir)
  discard result.server.start(result.inputPipe)

  result.client = StreamConnection.new(result.pipeClient)
  discard result.client.start(asyncPipeInput(result.pipeServer))

  result.suggestInit = FutureStream[ProgressParams]()
  result.client.register("window/workDoneProgress/create",
                            partial(testHandler[ProgressParams, JsonNode],
                                    (result.suggestInit, newJNull())))

  result.configInit = FutureStream[ConfigurationParams]()
  result.client.register(
    "workspace/configuration",
    partial(testHandler[ConfigurationParams, JsonNode],
            (result.configInit, workspaceConfiguration)))
  
  result.diagnostics = FutureStream[PublishDiagnosticsParams]()
  result.client.registerNotification(
    "textDocument/publishDiagnostics",
    partial(testHandler[PublishDiagnosticsParams], result.diagnostics))
  
  result.progress = FutureStream[ProgressParams]()
  result.client.registerNotification(
    "$/progress",
    partial(testHandler[ProgressParams], result.progress))
  
  result.showMessage = FutureStream[ShowMessageParams]()
  result.client.registerNotification(
    "window/showMessage",
    partial(testHandler[ShowMessageParams], result.showMessage))
  
  let initParams = InitializeParams %* {
      # "processId": %getCurrentProcessId(),
      "capabilities": {
        "window": {
          "workDoneProgress": true
        },
        "workspace": {"configuration": true}
      }
  }
  echo "pre"
  discard waitFor result.client.call("initialize", %initParams)
  echo "initialized"
  result.client.notify("initialized", newJObject())


template initLangServerForTestProject(workspaceConfiguration: JsonNode, rootPath: string) {.dirty.}= 
  
  let pipeServer = createPipe();
  let pipeClient = createPipe();

  let
    server = StreamConnection.new(pipeServer)
    inputPipe = asyncPipeInput(pipeClient)
    storageDir = ensureStorageDir()

  discard registerHandlers(server, inputPipe, storageDir);
  discard server.start(inputPipe);

  let client = StreamConnection.new(pipeClient);
  discard client.start(asyncPipeInput(pipeServer));

  let suggestInit = FutureStream[ProgressParams]()
  client.register("window/workDoneProgress/create",
                            partial(testHandler[ProgressParams, JsonNode],
                                    (fut: suggestInit, res: newJNull())))

  let configInit = FutureStream[ConfigurationParams]()
  client.register(
    "workspace/configuration",
    partial(testHandler[ConfigurationParams, JsonNode],
            (fut: configInit, res: workspaceConfiguration)))

  let diagnostics = FutureStream[PublishDiagnosticsParams]()
  client.registerNotification(
    "textDocument/publishDiagnostics",
    partial(testHandler[PublishDiagnosticsParams], diagnostics))

  let progress = FutureStream[ProgressParams]()
  client.registerNotification(
    "$/progress",
    partial(testHandler[ProgressParams], progress))

  let showMessage = FutureStream[ShowMessageParams]()
  client.registerNotification(
    "window/showMessage",
    partial(testHandler[ShowMessageParams], showMessage))

  let initParams = InitializeParams %* {
      "processId": %getCurrentProcessId(),
      "capabilities": {
        "window": {
          "workDoneProgress": true
        },
        "workspace": {"configuration": true}
      },
      "rootPath": %*rootPath
  }

  discard waitFor client.call("initialize", %initParams)
  client.notify("initialized", newJObject())


suite "nimble setup":
  
  test "should pick `testproject.nim` as the main file and provide suggestions":
    let testProjectDir = absolutePath "tests" / "projects" / "testproject"
    let entryPoint = testProjectDir / "src" / "testproject.nim"
    createNimbleProject(testProjectDir)
    var nlsConfig = %* [{
      "workingDirectoryMapping": [{ 
          "directory": testProjectDir,
          "file": entryPoint,
          "projectFile": entryPoint
      }],
      "autoCheckFile": false,
      "autoCheckProject": false
    }]
    initLangServerForTestProject(nlsConfig, testProjectDir)
    # #At this point we should know the main file is `testproject.nim` but for now just test the case were we open it
    client.notify("textDocument/didOpen", %createDidOpenParams(entryPoint))
    let (_, params) = suggestInit.read.waitFor
    let nimsuggestNot = notificationOutputs[^1]["value"]["title"].getStr
    check nimsuggestNot == &"Creating nimsuggest for {entryPoint}"
    
    let completionParams = CompletionParams %* {
      "position": {
         "line": 7,
         "character": 0
      },
      "textDocument": {
         "uri": pathToUri(entryPoint)
       }
    }
    #We need to call it twice, so we ignore the first call.
    var res =  client.call("textDocument/completion", %completionParams).waitFor
    res = client.call("textDocument/completion", %completionParams).waitFor
    let completionList = res.to(seq[CompletionItem]).mapIt(it.label)
    check completionList.len > 0

    var resStatus =  client.call("extension/status", %()).waitFor
    let status = resStatus.to(NimLangServerStatus)[]
    # check status.nimsuggestInstances.len == 2
    let nsInfo = status.nimsuggestInstances[0]
    check nsInfo.projectFile == entryPoint
  

  test "`submodule.nim` should not be part of the nimble project file":
    let testProjectDir = absolutePath "tests" / "projects" / "testproject"
    let entryPoint = testProjectDir / "src" / "testproject.nim"

    createNimbleProject(testProjectDir)
    var nlsConfig = %* [{
      "workingDirectoryMapping": [{ 
          "directory": testProjectDir,
          "file": entryPoint,
          "projectFile": entryPoint
      }],
      "autoCheckFile": false,
      "autoCheckProject": false
    }]
    initLangServerForTestProject(nlsConfig, testProjectDir)

    let submodule = testProjectDir / "src" / "testproject" / "submodule.nim"
    client.notify("textDocument/didOpen", %createDidOpenParams(submodule))
    discard suggestInit.read.waitFor

    # Entry point is still the same. 
    let nimsuggestNot = notificationOutputs[^1]["value"]["title"].getStr
    check nimsuggestNot == &"Creating nimsuggest for {entryPoint}"
    #Nimsuggest should still be able to give suggestions for the submodule
    let completionParams = CompletionParams %* {
      "position": {
         "line": 8,
         "character": 2
      },
      "textDocument": {
         "uri": pathToUri(submodule)
       }
    }
    
    #We need to call it twice, so we ignore the first call.
    var res =  client.call("textDocument/completion", %completionParams).waitFor
    res = client.call("textDocument/completion", %completionParams).waitFor
    let completionList = res.to(seq[CompletionItem]).mapIt(it.label)
    var resStatus =  client.call("extension/status", %()).waitFor
    let status = resStatus.to(NimLangServerStatus)[]
    if nsUnknownFile in status.nimsuggestInstances[0].capabilities:
      #Only check when the current nimsuggest instance supports unknown files as this wont work in previous versions
      check completionList.len > 0
      echo status

      check status.nimsuggestInstances.len == 1
      let nsInfo = status.nimsuggestInstances[0]
      check nsInfo.projectFile == entryPoint
      check status.openFiles.len == 2
      check entryPoint in status.openFiles
      check submodule in status.openFiles 


    


