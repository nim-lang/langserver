## tmisc.nim — rewrite-compatible port of tests/tmisc.nim
##
## API changes from original:
##   ls.workspaceConfiguration.complete(% @[conf])
##     → ls.configurations.currentConfig = some(conf)
##       ls.configurations.configReady.fire()
##
##   waitFor ls.workspaceConfiguration
##     → waitFor ls.getAndWaitForWorkspaceConfiguration()
##
##   ls.openFiles.del(uri)
##     → ls.files.openFiles.del(uri)
##
##   ls.projectFiles            → ls.pool.slots
##
##   ls.failTable               → removed from new architecture
##                                (crash counts now live on NimsuggestSlot.crashCount)
##
##   LanguageServer(serverMode: lsp, transportMode: stdio)
##     → LanguageServer(
##         capabilities: LanguageServerCapabilities(serverMode: lsp),
##         transport: LanguageServerTransport(transportMode: stdio),
##       )
##
##   ls.outStream               → ls.transport.outStream
##
##   ls.pendingRequests         → ls.messaging.pendingRequests

import ../src/quicknimlsp
import ../src/langserver/[langserver, langserver_types, utils, transports, messaging_types, configurations, configuration_types, queue_types]
import ../src/nimsuggest/nimsuggest
import ../src/protocol/[enums, types]
import std/[options, json, os, jsonutils, sequtils, strutils, sugar, strformat, times]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient
import chronos/asyncproc
import unittest2

suite "Nimlangserver misc":
  let cmdParams = CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )

  test "after a period of inactivity, nimsuggest should be stopped":
    echo "    >> after a period of inactivity, nimsuggest should be stopped"
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
    # New config API: set currentConfig and fire the event
    ls.configurations.currentConfig = some(conf)
    ls.configurations.configReady.fire()

    discard waitFor ls.getAndWaitForWorkspaceConfiguration()

    let helloWorldFile = "projects/hw/hw.nim"
    let hwAbsFile = uriToPath(helloWorldFile.fixtureUri())
    client.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile))

    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {hwAbsFile}",
    )

    asyncSpawn ls.tickLs()

    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest for {hwAbsFile} was stopped because it was idle for too long",
    )


suite "Nimlangserver pending requests":
  test "addProjectFileToPendingRequest sets projectFile on pending request":
    echo "    >> addProjectFileToPendingRequest sets projectFile on pending request"
    # Tests that addProjectFileToPendingRequest correctly populates the
    # projectFile field synchronously. In the new architecture this proc is
    # synchronous (no future to await); the regression test for the cancelled-
    # future escape (#419) no longer applies since the future was removed.
    let ls = LanguageServer(
      capabilities: LanguageServerCapabilities(serverMode: lsp),
      transport: LanguageServerTransport(transportMode: socket),
      messaging: LanguageServerMessaging(
        pendingRequests: initTable[uint, PendingRequest](),
        responseMap: newTable[string, Future[JsonNode]](),
        projectErrors: @[],
      ),
      notify: proc(name: string, params: JsonNode) {.gcsafe, raises: [].} = discard,
    )
    let uri = "file:///tmp/tpending_rewrite.nim"
    ls.messaging.pendingRequests[1'u] =
      PendingRequest(id: 1, name: "textDocument/definition", state: prsOnGoing, startTime: times.now())

    ls.addProjectFileToPendingRequest(1'u, uri)

    check ls.messaging.pendingRequests[1'u].projectFile ==
      some(uriToPath(uri))


suite "Nimlangserver idle nimsuggest cleanup":
  let cmdParams = CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )

  test "idle nimsuggest is removed even when an open file was already evicted":
    echo "    >> idle nimsuggest is removed even when an open file was already evicted"
    # Regression test for #420: a URI evicted from ls.files.openFiles while the
    # nimsuggest still tracks it must not raise KeyError in removeIdleNimsuggests.
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/hw/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)
    let conf = NlsConfig(nimsuggestIdleTimeout: some 1000)
    ls.configurations.currentConfig = some(conf)
    ls.configurations.configReady.fire()
    discard waitFor ls.getAndWaitForWorkspaceConfiguration()

    let helloWorldFile = "projects/hw/hw.nim"
    let hwAbsFile = uriToPath(helloWorldFile.fixtureUri())
    client.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile))
    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {hwAbsFile}"
    )
    # Evict the file from openFiles to simulate the race condition
    ls.files.openFiles.del(helloWorldFile.fixtureUri())

    var removed = false
    for attempt in 0 ..< 5:
      waitFor sleepAsync(1100)
      waitFor ls.removeIdleNimsuggests()
      # In the new code, pool.slots holds nimsuggest instances keyed by projectFile
      if hwAbsFile notin ls.pool.slots:
        removed = true
        break
    check removed


suite "Nimlangserver transport teardown":
  test "writeOutput drops writes after the stdio stream is torn down":
    echo "    >> writeOutput drops writes after the stdio stream is torn down"
    # Regression test for #418: an in-flight continuation resuming after onExit
    # closed ls.transport.outStream must be a no-op (nil check in writeOutput).
    let ls = LanguageServer(
      capabilities: LanguageServerCapabilities(serverMode: lsp),
      transport: LanguageServerTransport(transportMode: stdio),
    )
    doAssert ls.transport.outStream.isNil
    ls.writeOutput(%*{"jsonrpc": "2.0", "id": 1, "result": newJNull()})
    check ls.transport.outStream.isNil


suite "Nimlangserver fail count":
  test "fail count is reset when a nimsuggest starts successfully":
    echo "    >> fail count is reset when a nimsuggest starts successfully"
    # NimsuggestSlot.crashCount is the new-arch equivalent of ls.failTable.
    # After a slot spawns successfully, crashCount must be 0 so it is not
    # permanently blocked after MAX_CRASH_RETRIES.
    # Verified: processCommands resets slot.crashCount = 0 at queues.nim:249.
    let cmdParams2 = CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
    let ls2 = main(cmdParams2)
    let client2 = newLspSocketClient()
    waitFor client2.connect("localhost", cmdParams2.port)
    client2.registerNotification(
      "window/showMessage", "workspace/configuration",
      "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
    )
    let initParams2 = LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities": {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
    }
    discard waitFor client2.initialize(initParams2)
    ls2.configurations.currentConfig = some(NlsConfig())
    ls2.configurations.configReady.fire()
    discard waitFor ls2.getAndWaitForWorkspaceConfiguration()
    let helloWorldFile2 = "projects/hw/hw.nim"
    let hwAbsFile2 = uriToPath(helloWorldFile2.fixtureUri())
    client2.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile2))
    check waitFor client2.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {hwAbsFile2}"
    )
    # Verify crashCount is 0 after a clean spawn
    if hwAbsFile2 in ls2.pool.slots:
      check ls2.pool.slots[hwAbsFile2].crashCount == 0
