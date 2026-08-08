## textensions.nim — rewrite-compatible port of tests/textensions.nim
##
## API changes from original:
##   ls.projectFiles[hwAbsFile].process.pid
##     → the new code stores nimsuggest process inside NimSuggest.project.process.
##       Access: ls.pool.slots[hwAbsFile].resolvedNs.get.project.process.pid
##
##   ls.workspaceConfiguration.complete(% @[NlsConfig()])
##     → ls.configurations.currentConfig = some(NlsConfig())
##       ls.configurations.configReady.fire()

import ../src/quicknimlsp
import ../src/langserver/[langserver, langserver_types, utils, configurations]
import ../src/utils/utils
import ../src/configurations/configuration_types
import ../src/nimsuggest/nimsuggest_slots
import ../src/protocol/[enums, types]
import std/[options, json, os, jsonutils, sequtils, strutils, sugar, strformat]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient
import chronos/asyncproc
import testhelpers
import unittest2

suite "Nimlangserver extensions":
  let cmdParams = CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )

  test "calling extension/suggest with restart in the project uri should restart nimsuggest":
    echo "    >> calling extension/suggest with restart in the project uri should restart nimsuggest"
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/hw/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    let initializeResult = waitFor client.initialize(initParams)
    ls.configurations.currentConfig = some(NlsConfig())
    ls.configurations.configReady.fire()
    client.notify("initialized", newJObject())

    check initializeResult.capabilities.textDocumentSync.isSome

    let helloWorldFile = "projects/hw/hw.nim"
    let hwAbsFile = uriToPath(helloWorldFile.fixtureUri())
    client.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile))

    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {hwAbsFile}",
    )

    # Get PID before restart via the new slot API.
    # Note: we do NOT open useRoot.nim here — with maxSlots=1 that would evict
    # the hw.nim slot via EVICT_AND_SPAWN before we can restart it.
    # NimSuggest.project.process holds the AsyncProcessRef.
    let slotBefore = ls.pool.slots.getOrDefault(hwAbsFile)
    check slotBefore != nil
    let nsBefore = slotBefore.resolvedNs
    check nsBefore.isSome
    let prevPid = nsBefore.get.project.process.pid

    # Clear old window/showMessage calls so the "initialized" check below only
    # matches a NEW notification from the restart, not the one from initial spawn.
    client.calls["window/showMessage"] = @[]

    let suggestParams = SuggestParams(action: saRestart, projectFile: hwAbsFile)
    discard client.call("extension/suggest", %suggestParams).waitFor

    # Wait for re-init notification that arrives after the restart completes.
    # Use a longer poll loop since compilation can take >10s.
    var gotInit = false
    for _ in 0 ..< 30:  # up to 30s
      waitFor sleepAsync(1000)
      let msgs = client.calls.getOrDefault("window/showMessage", @[])
      if msgs.anyIt(it["message"].to(string) == fmt"Nimsuggest initialized for {hwAbsFile}"):
        gotInit = true
        break
    check gotInit

    let slotAfter = ls.pool.slots.getOrDefault(hwAbsFile)
    # Debug: print actual slot keys if lookup fails
    if slotAfter == nil:
      echo "DEBUG slot keys: ", ls.pool.slots.keys.toSeq
      echo "DEBUG hwAbsFile: ", hwAbsFile
    check slotAfter != nil
    if slotAfter != nil:
      let nsAfter = slotAfter.resolvedNs
      check nsAfter.isSome
      if nsAfter.isSome:
        let newPid = nsAfter.get.project.process.pid
        check prevPid != newPid

  test "calling extension/tasks should return all existing tasks":
    echo "    >> calling extension/tasks should return all existing tasks"
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/tasks/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)

    let tasksFile = "projects/tasks/src/tasks.nim"
    client.notify("textDocument/didOpen", %createDidOpenParams(tasksFile))

    let tasks = client.call("extension/tasks", jsonutils.toJson(())).waitFor().jsonTo(
        seq[NimbleTask]
      )

    check tasks.len == 3
    check tasks[0].name == "helloWorld"
    check tasks[0].description == "hello world"

  test "calling extension/listTests should return all existing tests":
    echo "    >> calling extension/listTests should return all existing tests"
    let projectDir = getCurrentDir() / "tests" / "projects" / "testrunner"
    cd projectDir:
      let (output, _) = execNimble("install", "-l")
      discard execNimble("setup")

    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testrunner/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)

    let listTestsParams = ListTestsParams(entryPoint: some("tests/projects/testrunner/tests/sampletests.nim".absolutePath))
    let tests = client.call("extension/listTests", jsonutils.toJson(listTestsParams)).waitFor().jsonTo(
        ListTestsResult, Joptions(allowMissingKeys: true)
      )
    let testProjectInfo = tests.projectInfo
    check testProjectInfo.suites.len == 3
    check testProjectInfo.suites["Sample Tests"].tests.len == 1
    check testProjectInfo.suites["Sample Tests"].tests[0].name == "Sample Test alone"
    check testProjectInfo.suites["Sample Tests"].tests[0].file == "sampletests.nim"
    check testProjectInfo.suites["Sample Tests"].tests[0].line == 4

  test "calling extension/runTests should run the tests and return the results":
    echo "    >> calling extension/runTests should run the tests and return the results"
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testrunner/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)

    let runTestsParams = RunTestParams(entryPoint: "tests/projects/testrunner/tests/sampletests.nim".absolutePath)
    let runTestsRes = client.call("extension/runTests", jsonutils.toJson(runTestsParams)).waitFor().jsonTo(
        RunTestProjectResult, Joptions(allowMissingKeys: true)
      )
    check runTestsRes.suites.len == 4
    check runTestsRes.suites[0].name == "Sample Tests"
    check runTestsRes.suites[0].tests == 1
    check runTestsRes.suites[0].failures == 0
    check runTestsRes.suites[0].errors == 0
    check runTestsRes.suites[0].skipped == 0
    check runTestsRes.suites[0].time > 0.0 and runTestsRes.suites[0].time < 1.0

  test "calling extension/runTest with a suite name should run the tests in the suite":
    echo "    >> calling extension/runTest with a suite name should run the tests in the suite"
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testrunner/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)

    let suiteName = "Sample Suite"
    let runTestsParams = RunTestParams(
      entryPoint: "tests/projects/testrunner/tests/sampletests.nim".absolutePath,
      suiteName: some suiteName,
    )
    let runTestsRes = client.call("extension/runTests", jsonutils.toJson(runTestsParams)).waitFor().jsonTo(
        RunTestProjectResult, Joptions(allowMissingKeys: true)
      )
    check runTestsRes.suites.len == 1
    check runTestsRes.suites[0].name == suiteName
    check runTestsRes.suites[0].tests == 3

  test "calling extension/runTest with a test name should run the tests in the suite":
    echo "    >> calling extension/runTest with a test name should run the tests in the suite"
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testrunner/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)

    let testName = "Sample Test"
    let runTestsParams = RunTestParams(
      entryPoint: "tests/projects/testrunner/tests/sampletests.nim".absolutePath,
      testNames: some @[testName],
    )
    let runTestsRes = client.call("extension/runTests", jsonutils.toJson(runTestsParams)).waitFor().jsonTo(
        RunTestProjectResult, Joptions(allowMissingKeys: true)
      )
    check runTestsRes.suites.len == 1
    check runTestsRes.suites[0].tests == 1
    check runTestsRes.suites[0].testResults[0].name == testName

  test "calling extension/runTest with a failing test should return the failure":
    echo "    >> calling extension/runTest with a failing test should return the failure"
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testrunner/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)

    let runTestsParams = RunTestParams(
      entryPoint: "tests/projects/testrunner/tests/failingtest.nim".absolutePath
    )
    let runTestsRes = client.call("extension/runTests", jsonutils.toJson(runTestsParams)).waitFor().jsonTo(
        RunTestProjectResult, Joptions(allowMissingKeys: true)
      )
    check runTestsRes.suites.len == 1
    check runTestsRes.suites[0].name == "Failing Tests"
    check runTestsRes.suites[0].tests == 2
    check runTestsRes.suites[0].failures == 1
    check runTestsRes.suites[0].testResults[0].name == "Failing Test"
    check runTestsRes.suites[0].testResults[0].failure.isSome
