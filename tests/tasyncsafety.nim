import ../[nimlangserver, ls, utils]
import ../suggestapi
import ../protocol/types
import std/[options, os, tables, json]
import chronos
import lspsocketclient
import testhelpers
import unittest2

suite "Async safety":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )

  let initParams =
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities":
        {"window": {"workDoneProgress": false}, "workspace": {"configuration": true}},
    }
  discard waitFor client.initialize(initParams)

  let
    helloWorldFile = "projects/hw/hw.nim"
    helloWorldUri = fixtureUri(helloWorldFile)
    helloWorldPath = uriToPath(helloWorldUri)

  test "didOpenFile writes the stash file before it suspends":
    removeFile(ls.uriStorageLocation(helloWorldUri))
    let textDocument = TextDocumentItem(
      uri: helloWorldUri,
      languageId: "nim",
      version: 0,
      text: readFile("tests" / helloWorldFile),
    )

    let opened = ls.didOpenFile(textDocument)
    check fileExists(ls.uriStorageLocation(helloWorldUri))
    check ls.openFiles[helloWorldUri].fingerTable.len > 0

    waitFor opened.wait(30.seconds)

  test "Concurrent creations for the same project are deduplicated":
    let first = ls.createOrRestartNimsuggest(helloWorldPath, helloWorldUri)
    let second = ls.createOrRestartNimsuggest(helloWorldPath, helloWorldUri)
    check ls.nimsuggestCreations.len == 1

    waitFor allFutures(first, second).wait(30.seconds)
    check ls.nimsuggestCreations.len == 0
    check ls.projectFiles.len == 1
    check not ls.projectFiles[helloWorldPath].process.isNil

  test "The server survives a client that leaves with a request pending":
    let leaving = newLspSocketClient()
    waitFor leaving.connect("localhost", cmdParams.port)
    let pending = ls.call("workspace/configuration", newJNull())
    check not pending.isNil
    waitFor leaving.transport.closeWait()
    waitFor sleepAsync(500.milliseconds)

    let revived = newLspSocketClient()
    waitFor revived.connect("localhost", cmdParams.port)
    let res = waitFor revived.call("shutdown", newJNull()).wait(30.seconds)
    check res.kind == JNull

suite "Replacing a running nimsuggest":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )
  discard waitFor client.initialize(
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities":
        {"window": {"workDoneProgress": false}, "workspace": {"configuration": true}},
    }
  )

  let
    helloWorldFile = "projects/hw/hw.nim"
    helloWorldUri = fixtureUri(helloWorldFile)
    helloWorldPath = uriToPath(helloWorldUri)

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "stopping the replaced instance is not handled as a crash":
    let textDocument = TextDocumentItem(
      uri: helloWorldUri,
      languageId: "nim",
      version: 0,
      text: readFile("tests" / helloWorldFile),
    )
    waitFor ls.didOpenFile(textDocument).wait(30.seconds)
    let old = ls.projectFiles[helloWorldPath]
    let oldNs = waitFor old.ns.wait(30.seconds)
    # Having served a request is what made the error path auto-restart it.
    check waitUntil(oldNs.successfullCall, timeout = 30.seconds)

    waitFor ls.createOrRestartNimsuggest(helloWorldPath, helloWorldUri).wait(30.seconds)
    let replacement = ls.projectFiles[helloWorldPath]
    check replacement != old

    # Wait for the old process to be gone and its stderr closing handled, then
    # give anything that triggers time to run.
    check waitUntil(old.failed, timeout = 30.seconds)
    waitFor sleepAsync(2.seconds)

    check ls.failTable.getOrDefault(helloWorldPath, 0) == 0
    check ls.nimsuggestCreations.len == 0
    check ls.projectFiles[helloWorldPath] == replacement
    check not replacement.failed
