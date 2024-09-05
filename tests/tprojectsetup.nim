import ../[
  nimlangserver, ls, lstransports, utils
]
import ../protocol/[enums, types]
import std/[options, unittest, json, os, jsonutils, sequtils, strutils, sugar, strformat, osproc]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient

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


proc createNimbleProject(projectDir: string) = 
  cdNewDir projectDir:     
    let (output, exitCode) = execNimbleYes("init")
    check exitCode == 0


suite "nimble setup":
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", 
    "window/workDoneProgress/create",
    "workspace/configuration",
    "extension/statusUpdate",
    "extension/statusUpdate",
    "textDocument/publishDiagnostics",
    "$/progress"
    )

  test "should pick `testproject.nim` as the main file and provide suggestions":
    let testProjectDir = absolutePath "tests" / "projects" / "testproject"
    let entryPoint = testProjectDir / "src" / "testproject.nim"
    createNimbleProject(testProjectDir)
    let initParams = InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testproject"),
        "capabilities": {
          "window": {
            "workDoneProgress": true
          },
          "workspace": {"configuration": true}
        }
    }
    discard waitFor client.initialize(initParams)
    let progressParam = %ProgressParams(token: fmt "Creating nimsuggest for {entryPoint}")
    check waitFor client.waitForNotification("$/progress", (json: JsonNode) => progressParam["token"] == json["token"])
    
    let completionParams = CompletionParams %* {
      "position": {
         "line": 7,
         "character": 0
      },
      "textDocument": {
         "uri": pathToUri(entryPoint)
       }
    }
    echo pathToUri(entryPoint)
    let ns = waitFor ls.projectFiles[entryPoint]
    client.notify("textDocument/didOpen", %createDidOpenParams("projects/testproject/src/testproject.nim"))
    check waitFor client.waitForNotification("window/showMessage", 
      (json: JsonNode) => json["message"].jsonTo(string) == &"Opening {pathToUri(entryPoint)}")

    #We need to make two calls (ns issue)
    discard client.call("textDocument/completion", %completionParams).waitFor
    let completionList =  client.call("textDocument/completion", %completionParams)
      .waitFor.to(seq[CompletionItem]).mapIt(it.label)
    check completionList.len > 0
    # echo res
    
    # client.notify("textDocument/didOpen", %createDidOpenParams(entryPoint))
    
    
  # test "should pick `testproject.nim` as the main file and provide suggestions":
  #   let testProjectDir = absolutePath "tests" / "projects" / "testproject"
  #   let entryPoint = testProjectDir / "src" / "testproject.nim"
  #   createNimbleProject(testProjectDir)
  #   var nlsConfig = %* [{
  #     "workingDirectoryMapping": [{ 
  #         "directory": testProjectDir,
  #         "file": entryPoint,
  #         "projectFile": entryPoint
  #     }],
  #     "autoCheckFile": false,
  #     "autoCheckProject": false
  #   }]
  #   initLangServerForTestProject(nlsConfig, testProjectDir)
  #   # #At this point we should know the main file is `testproject.nim` but for now just test the case were we open it
  #   client.notify("textDocument/didOpen", %createDidOpenParams(entryPoint))
  #   let (_, params) = suggestInit.read.waitFor
  #   let nimsuggestNot = notificationOutputs[^1]["value"]["title"].getStr
  #   check nimsuggestNot == &"Creating nimsuggest for {entryPoint}"
    
  #   let completionParams = CompletionParams %* {
  #     "position": {
  #        "line": 7,
  #        "character": 0
  #     },
  #     "textDocument": {
  #        "uri": pathToUri(entryPoint)
  #      }
  #   }
  #   #We need to call it twice, so we ignore the first call.
  #   var res =  client.call("textDocument/completion", %completionParams).waitFor
  #   res = client.call("textDocument/completion", %completionParams).waitFor
  #   let completionList = res.to(seq[CompletionItem]).mapIt(it.label)
  #   check completionList.len > 0

  #   var resStatus =  client.call("extension/status", %()).waitFor
  #   let status = resStatus.to(NimLangServerStatus)[]
  #   # check status.nimsuggestInstances.len == 2
  #   let nsInfo = status.nimsuggestInstances[0]
  #   check nsInfo.projectFile == entryPoint
  

  # test "`submodule.nim` should not be part of the nimble project file":
  #   let testProjectDir = absolutePath "tests" / "projects" / "testproject"
  #   let entryPoint = testProjectDir / "src" / "testproject.nim"

  #   createNimbleProject(testProjectDir)
  #   var nlsConfig = %* [{
  #     "workingDirectoryMapping": [{ 
  #         "directory": testProjectDir,
  #         "file": entryPoint,
  #         "projectFile": entryPoint
  #     }],
  #     "autoCheckFile": false,
  #     "autoCheckProject": false
  #   }]
  #   initLangServerForTestProject(nlsConfig, testProjectDir)

  #   let submodule = testProjectDir / "src" / "testproject" / "submodule.nim"
  #   client.notify("textDocument/didOpen", %createDidOpenParams(submodule))
  #   discard suggestInit.read.waitFor

  #   # Entry point is still the same. 
  #   let nimsuggestNot = notificationOutputs[^1]["value"]["title"].getStr
  #   check nimsuggestNot == &"Creating nimsuggest for {entryPoint}"
  #   #Nimsuggest should still be able to give suggestions for the submodule
  #   let completionParams = CompletionParams %* {
  #     "position": {
  #        "line": 8,
  #        "character": 2
  #     },
  #     "textDocument": {
  #        "uri": pathToUri(submodule)
  #      }
  #   }
    
  #   #We need to call it twice, so we ignore the first call.
  #   var res =  client.call("textDocument/completion", %completionParams).waitFor
  #   res = client.call("textDocument/completion", %completionParams).waitFor
  #   let completionList = res.to(seq[CompletionItem]).mapIt(it.label)
  #   var resStatus =  client.call("extension/status", %()).waitFor
  #   let status = resStatus.to(NimLangServerStatus)[]
  #   if nsUnknownFile in status.nimsuggestInstances[0].capabilities:
  #     #Only check when the current nimsuggest instance supports unknown files as this wont work in previous versions
  #     check completionList.len > 0
  #     echo status

  #     check status.nimsuggestInstances.len == 1
  #     let nsInfo = status.nimsuggestInstances[0]
  #     check nsInfo.projectFile == entryPoint
  #     check status.openFiles.len == 2
  #     check entryPoint in status.openFiles
  #     check submodule in status.openFiles 


    


