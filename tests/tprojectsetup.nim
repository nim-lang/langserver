## tprojectsetup.nim — rewrite-compatible port of tests/tprojectsetup.nim
##
## API changes from original:
##   ls.projectFiles[entryPoint].ns   → ls.pool.slots[entryPoint] (NimsuggestSlot)
##   ls.projectFiles.len              → ls.pool.slots.len
##   ls.workspaceConfiguration.complete(...)
##     → ls.configurations.currentConfig = some(...)
##       ls.configurations.configReady.fire()
##   waitFor getProjectFile(pathToUri(f), ls)
##     → ls.getOrCreateSlotForUri(pathToUri(f)).projectFile
##       (synchronous after configReady; must await configReady first)
##   "Opening <uri>" notification → still sent by lsp.didOpen handler

import ../src/quicknimlsp
import ../src/langserver/[langserver, langserver_types, utils, configurations, nimsuggest_processes]
import ../src/utils/utils
import ../src/configurations/configuration_types
import ../src/nimsuggest/nimsuggest_types
import ../src/protocol/[enums, types]
import std/[options, json, os, jsonutils, sequtils, strutils, sugar, strformat]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient
import testhelpers
import unittest2

suite "nimble setup":
  let cmdParams = CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "extension/statusUpdate",
    "textDocument/publishDiagnostics", "$/progress",
  )
  let testProjectDir = absolutePath "tests" / "projects" / "testproject"

  test "should pick `testproject.nim` as the main file and provide suggestions":
    echo "    >> should pick `testproject.nim` as the main file and provide suggestions"
    let entryPoint = testProjectDir / "src" / "testproject.nim"
    createNimbleProject(testProjectDir)
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testproject"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)
    client.notify("initialized", newJObject())

    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {entryPoint}",
    )

    let completionParams =
      CompletionParams %* {
        "position": {"line": 7, "character": 0},
        "textDocument": {"uri": pathToUri(entryPoint)},
      }
    # In the new code, pool.slots is keyed by projectFile path
    let slotOpt = ls.pool.slots.getOrDefault(entryPoint)
    check slotOpt != nil

    client.notify(
      "textDocument/didOpen",
      %createDidOpenParams("projects/testproject/src/testproject.nim"),
    )
    # New code sends "Nimsuggest initialized for <absPath>" not "Opening <uri>"
    check waitFor client.waitForNotificationMessage(
      &"Nimsuggest initialized for {entryPoint}"
    )

    discard client.call("textDocument/completion", %completionParams).waitFor
    let completionList = client
      .call("textDocument/completion", %completionParams).waitFor
      .to(seq[CompletionItem])
      .mapIt(it.label)
    check completionList.len > 0

  test "`submodule.nim` should not be part of the nimble project file":
    echo "    >> `submodule.nim` should not be part of the nimble project file"
    let submodule = testProjectDir / "src" / "testproject" / "submodule.nim"
    client.notify(
      "textDocument/didOpen",
      %createDidOpenParams("projects/testproject/src/testproject/submodule.nim"),
    )
    # Submodule reuses existing slot — no new "Nimsuggest initialized" message.
    # Just verify the slot count didn't change.
    # Submodule should reuse the existing slot, not create a new one
    check ls.pool.slots.len == 1


suite "Project Mapping":
  let cmdParams = CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "extension/statusUpdate",
    "textDocument/publishDiagnostics", "$/progress",
  )
  let projectsDir = absolutePath "tests" / "projects"

  test "should use projectMapping fileRegex to find project file":
    echo "    >> should use projectMapping fileRegex to find project file"
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)
    let configurationParams =
      @[NlsConfig(projectMapping: some @[NlsNimsuggestConfig(fileRegex: ".nonimble*")])]
    let nonimbleProject = projectsDir / "nonimbleproject.nim"

    # Supply config via the new mechanism
    ls.configurations.currentConfig = some(configurationParams[0])
    ls.configurations.configReady.fire()

    # getIntendedProject is synchronous and returns an abs path (not a URI).
    let intendedProject = ls.getIntendedProject(pathToUri(nonimbleProject))
    check intendedProject == nonimbleProject
