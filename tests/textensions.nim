import ../[nimlangserver, ls, lstransports, utils]
import ../protocol/[enums, types]
import
  std/[options, unittest, json, os, jsonutils, sequtils, strutils, sugar, strformat]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient
import chronos/asyncproc

suite "Nimlangserver":
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )

  test "calling extension/suggest with restart in the project uri should restart nimsuggest":
    let initParams =
      InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/hw/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    let initializeResult = waitFor client.initialize(initParams)

    check initializeResult.capabilities.textDocumentSync.isSome

    let helloWorldUri = fixtureUri("projects/hw/hw.nim")
    let helloWorldFile = "projects/hw/hw.nim"
    let hwAbsFile = uriToPath(helloWorldFile.fixtureUri())
    client.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile))

    let progressParam =
      %ProgressParams(token: fmt "Creating nimsuggest for {hwAbsFile}")
    check waitFor client.waitForNotification(
      "$/progress", (json: JsonNode) => progressParam["token"] == json["token"]
    )
    check waitFor client.waitForNotification(
      "$/progress", (json: JsonNode) => json["value"]["kind"].getStr == "begin"
    )
    check waitFor client.waitForNotification(
      "$/progress", (json: JsonNode) => json["value"]["kind"].getStr == "end"
    )

    client.notify(
      "textDocument/didOpen", %createDidOpenParams("projects/hw/useRoot.nim")
    )

    let prevSuggestPid = ls.projectFiles[hwAbsFile].process.pid
    let suggestParams = SuggestParams(action: saRestart, projectFile: hwAbsFile)
    let suggestRes = client.call("extension/suggest", %suggestParams).waitFor
    let suggestPid = ls.projectFiles[hwAbsFile].process.pid

    check prevSuggestPid != suggestPid

  test "calling extension/tasks should return all existing tasks":
    let initParams =
      InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/tasks/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    let initializeResult = waitFor client.initialize(initParams)

    let tasksFile = "projects/tasks/src/tasks.nim"
    let taskAbsFile = uriToPath(tasksFile.fixtureUri())
    client.notify("textDocument/didOpen", %createDidOpenParams(tasksFile))

    let tasks = client.call("extension/tasks", jsonutils.toJson(())).waitFor().jsonTo(
        seq[NimbleTask]
      )

    check tasks.len == 2
    check tasks[0].name == "helloWorld"
    check tasks[0].description == "hello world"
