import ../[nimlangserver, ls, lstransports, utils]
import ../protocol/[enums, types]
import
  std/[options, json, os, jsonutils, sequtils, strutils, sugar, strformat]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient
import chronos/asyncproc
import unittest2

suite "Nimlangserver misc":
  let cmdParams = CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )

  test "after a period of inactivity, nimsuggest should be stopped":
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/hw/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    let initializeResult = waitFor client.initialize(initParams)
    let nsTimeout = 1000
    let conf = NlsConfig(nimsuggestIdleTimeout: some nsTimeout)
    ls.workspaceConfiguration.complete(% @[conf])
    
    let gConf = waitFor ls.workspaceConfiguration

    asyncSpawn ls.tickLs() #We need to tick the ls so it get rid of the inactive nimsuggests

    let helloWorldUri = fixtureUri("projects/hw/hw.nim")
    let helloWorldFile = "projects/hw/hw.nim"
    let hwAbsFile = uriToPath(helloWorldFile.fixtureUri())
    client.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile))

    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {hwAbsFile}",
    )
    
    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest for {hwAbsFile} was stopped because it was idle for too long",
    )

suite "Nimlangserver pending requests":
  test "cancelled projectFile future does not escape addProjectFileToPendingRequest":
    # Regression test for #419: addProjectFileToPendingRequest is asyncSpawn'd,
    # so an escaping CancelledError (nimsuggest restart or $/cancelRequest
    # cancelling the awaited projectFile future) is re-raised into the event
    # loop, escapes runForever and hits main's `except Exception: quit(1)`.
    # The spawned task must swallow cancellation instead of failing.
    let ls = LanguageServer(serverMode: lsp, transportMode: socket)
    let uri = "file:///tmp/tpending419.nim"
    let projectFileFut = newFuture[string]("projectFile")
    ls.openFiles[uri] = NlsFileInfo(projectFile: projectFileFut)
    ls.pendingRequests[1'u] = PendingRequest(id: 1, name: "textDocument/definition")

    let fut = ls.addProjectFileToPendingRequest(1'u, uri)
    projectFileFut.cancelSoon()
    waitFor sleepAsync(10)

    check fut.finished
    check fut.completed
