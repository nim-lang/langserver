import ../[nimlangserver, ls, lstransports, utils]
import ../protocol/[enums, types]
import
  std/[options, json, os, jsonutils, sequtils, strutils, sugar, strformat]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient
import chronos/asyncproc
import testhelpers
import unittest2

suite "Nimlangserver extensions":
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
    
    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {hwAbsFile}",
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

    check tasks.len == 3
    check tasks[0].name == "helloWorld"
    check tasks[0].description == "hello world"

  test "calling extension/listTests should return all existing tests":
    #We first need to initialize the nimble project
    let projectDir = getCurrentDir() / "tests" / "projects" / "testrunner"
    cd projectDir:
      let (output, _) = execNimble("install", "-l")
      discard execNimble("setup")

    let initParams =
      InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testrunner/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    let initializeResult = waitFor client.initialize(initParams)

    let listTestsParams = ListTestsParams(entryPoint: "tests/projects/testrunner/tests/sampletests.nim".absolutePath)
    let tests = client.call("extension/listTests", jsonutils.toJson(listTestsParams)).waitFor().jsonTo(
        ListTestsResult
      )
    let testProjectInfo = tests.projectInfo
    check testProjectInfo.suites.len == 3
    check testProjectInfo.suites["Sample Tests"].tests.len == 1
    check testProjectInfo.suites["Sample Tests"].tests[0].name == "Sample Test alone"
    check testProjectInfo.suites["Sample Tests"].tests[0].file == "sampletests.nim"
    check testProjectInfo.suites["Sample Tests"].tests[0].line == 4

  test "calling extension/runTests should run the tests and return the results":
    let initParams =
      InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testrunner/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    let initializeResult = waitFor client.initialize(initParams)

    let runTestsParams = RunTestParams(entryPoint: "tests/projects/testrunner/tests/sampletests.nim".absolutePath)
    let runTestsRes = client.call("extension/runTests", jsonutils.toJson(runTestsParams)).waitFor().jsonTo(
        RunTestProjectResult
      )
    check runTestsRes.suites.len == 4
    check runTestsRes.suites[0].name == "Sample Tests"
    check runTestsRes.suites[0].tests == 1
    check runTestsRes.suites[0].failures == 0
    check runTestsRes.suites[0].errors == 0
    check runTestsRes.suites[0].skipped == 0
    check runTestsRes.suites[0].time > 0.0 and runTestsRes.suites[0].time < 1.0

  test "calling extension/runTest with a suite name should run the tests in the suite":
    let initParams =
      InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testrunner/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    let initializeResult = waitFor client.initialize(initParams)

    let suiteName = "Sample Suite"
    let runTestsParams = RunTestParams(entryPoint: "tests/projects/testrunner/tests/sampletests.nim".absolutePath, suiteName: some suiteName)
    let runTestsRes = client.call("extension/runTests", jsonutils.toJson(runTestsParams)).waitFor().jsonTo(
        RunTestProjectResult
      )
    check runTestsRes.suites.len == 1
    check runTestsRes.suites[0].name == suiteName
    check runTestsRes.suites[0].tests == 3

  test "calling extension/runTest with a test name should run the tests in the suite":
    let initParams =
      InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testrunner/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    
    let initializeResult = waitFor client.initialize(initParams)

    let testName = "Sample Test"
    let runTestsParams = RunTestParams(entryPoint: "tests/projects/testrunner/tests/sampletests.nim".absolutePath, testNames: some @[testName])
    let runTestsRes = client.call("extension/runTests", jsonutils.toJson(runTestsParams)).waitFor().jsonTo(RunTestProjectResult)

    check runTestsRes.suites.len == 1
    check runTestsRes.suites[0].tests == 1
    check runTestsRes.suites[0].testResults[0].name == testName

    test "calling extension/runTest with multiple test names should run the tests in the suite":
      let initParams =
        InitializeParams %* {
          "processId": %getCurrentProcessId(),
          "rootUri": fixtureUri("projects/testrunner/"),
          "capabilities":
            {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
        }
      let initializeResult = waitFor client.initialize(initParams)

      let testNames = @["Sample Test", "Sample Test 2"]
      let runTestsParams = RunTestParams(entryPoint: "tests/projects/testrunner/tests/sampletests.nim".absolutePath, testNames: some testNames)
      let runTestsRes = client.call("extension/runTests", jsonutils.toJson(runTestsParams)).waitFor().jsonTo(RunTestProjectResult)

    check runTestsRes.suites.len == 1
  #   check runTestsRes.suites[0].tests == 2

  test "calling extension/runTest with a failing test should return the failure":
    let initParams =
      InitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testrunner/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
      
    let initializeResult = waitFor client.initialize(initParams)

    let runTestsParams = RunTestParams(entryPoint: "tests/projects/testrunner/tests/failingtest.nim".absolutePath)
    let runTestsRes = client.call("extension/runTests", jsonutils.toJson(runTestsParams)).waitFor().jsonTo(RunTestProjectResult)

    check runTestsRes.suites.len == 1
    check runTestsRes.suites[0].name == "Failing Tests"
    check runTestsRes.suites[0].tests == 2
    check runTestsRes.suites[0].failures == 1
    check runTestsRes.suites[0].testResults[0].name == "Failing Test"
    check runTestsRes.suites[0].testResults[0].failure.isSome
