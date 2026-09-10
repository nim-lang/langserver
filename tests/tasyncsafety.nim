import ../[nimlangserver, ls, utils]
import ../protocol/types
import std/[options, os, tables, json]
import chronos
import lspsocketclient
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
