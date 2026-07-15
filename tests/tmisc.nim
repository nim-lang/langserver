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

suite "Nimlangserver fail count":
  let cmdParams = CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )

  test "fail count is reset when a nimsuggest starts successfully":
    # ls.failTable only ever increments, so a project that crashes and
    # recovers keeps ratcheting toward MaxFails in getNimsuggest, after which
    # its requests are silently rerouted or dropped for the rest of the
    # session. A successful start must clear the count.
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/hw/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)
    ls.workspaceConfiguration.complete(% @[NlsConfig()])
    discard waitFor ls.workspaceConfiguration

    let helloWorldFile = "projects/hw/hw.nim"
    let hwAbsFile = uriToPath(helloWorldFile.fixtureUri())
    ls.failTable[hwAbsFile] = 5

    client.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile))
    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {hwAbsFile}"
    )

    check hwAbsFile notin ls.failTable

suite "Nimlangserver transport teardown":
  test "writeOutput drops writes after the stdio stream is torn down":
    # Regression test for #418: an in-flight runRpc continuation resuming after
    # onExit closed ls.outStream wrote to a closed FILE and SIGSEGV'd inside
    # libc fwrite. Test approach: the real crash needs a stdio teardown racing
    # an async write and cannot be reproduced in-process without taking the
    # test runner down with it, so we exercise the guarded state instead —
    # after onExit, outStream is nil and a late writeOutput must be a no-op
    # (pre-fix this dereferences a nil stream and dies).
    let ls = LanguageServer(serverMode: lsp, transportMode: stdio)
    doAssert ls.outStream.isNil
    ls.writeOutput(%*{"jsonrpc": "2.0", "id": 1, "result": newJNull()})
    check ls.outStream.isNil
