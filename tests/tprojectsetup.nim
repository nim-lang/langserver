
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

#[
  1. The tests setup a new nimble project and makes sure when initializing it, the main 
  file is set to `testproject.nim`
  2. Modify the file `testproject.nim` and import `submodule.nim` then test the file doesnt require another nimsuggest
]#
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

test "should pick `testproject.nim` as the main file":
  let testProjectDir = absolutePath "tests" / "projects" / "testproject"
  let entryPoint = testProjectDir / "src" / "testproject.nim"
  cdNewDir testProjectDir:
    let (output, exitCode) = execNimbleYes("init")
    check exitCode == 0
    
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
    let workspaceConfiguration = %* [{
        "workingDirectoryMapping": [{ 
            "directory": testProjectDir,
            "file": entryPoint,
            "projectFile": entryPoint
        }],
        "autoCheckFile": false,
        "autoCheckProject": false
    }]

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
        }
    }

    discard waitFor client.call("initialize", %initParams)
    client.notify("initialized", newJObject())
    # #At this point we should know the main file is `testproject.nim` but for now just test the case were we open it
    client.notify("textDocument/didOpen", %createDidOpenParams(entryPoint))
    let (_, params) = suggestInit.read.waitFor
    # echo "aqui"
    let nimsuggestNot = notificationOutputs[^1]["value"]["title"].getStr
    check nimsuggestNot == &"Creating nimsuggest for {entryPoint}"
    # check notificationOutputs[^1][^1]["title"].getStr == &"Creating nimsuggest for {entryPoint}"
    # echo params
  


