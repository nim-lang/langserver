import
  std/[options, json, os, sequtils, strformat, strutils],
  json_rpc/[rpcclient],
  chronos/asyncproc,
  unittest2,
  ../[nimlangserver, ls, lstransports2, suggestapi, utils],
  ../protocol/[types],
  ./[lspsocketclient, testhelpers]

suite "Nimlangserver misc":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

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
    ls.setWorkspaceConfiguration(% @[conf])

    asyncSpawn ls.tickLs()
      #We need to tick the ls so it get rid of the inactive nimsuggests

    let helloWorldUri = fixtureUri("projects/hw/hw.nim")
    let helloWorldFile = "projects/hw/hw.nim"
    let hwAbsFile = uriToPath(helloWorldFile.fixtureUri())
    client.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile))

    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {hwAbsFile}"
    )

    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest for {hwAbsFile} was stopped because it was idle for too long"
    )

suite "Nimlangserver fail count":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

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
    ls.setWorkspaceConfiguration(% @[NlsConfig()])

    let helloWorldFile = "projects/hw/hw.nim"
    let hwAbsFile = uriToPath(helloWorldFile.fixtureUri())
    ls.failTable[hwAbsFile] = 5

    client.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile))
    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {hwAbsFile}"
    )

    check hwAbsFile notin ls.failTable

suite "Nimlangserver pending requests":
  test "cancelled projectFile future does not escape addProjectFileToPendingRequest":
    # Regression test for #419: addProjectFileToPendingRequest is asyncSpawn'd,
    # so an escaping CancelledError (nimsuggest restart or $/cancelRequest
    # cancelling the awaited projectFile future) is re-raised into the event
    # loop, escapes runForever and hits main's `except Exception: quit(1)`.
    # The spawned task must swallow cancellation instead of failing.
    let ls = LanguageServer(serverMode: lsp)
    let uri = "file:///tmp/tpending419.nim"
    let projectFileFut =
      Future[string].Raising([CancelledError, OSError, RegexError]).init("projectFile")
    ls.openFiles[uri] = NlsFileInfo(projectFile: projectFileFut)
    ls.pendingRequests[1'u] = PendingRequest(id: 1, name: "textDocument/definition")

    let fut = ls.addProjectFileToPendingRequest(1'u, uri)
    projectFileFut.cancelSoon()

    check waitUntil(fut.finished)
    check fut.completed

suite "Nimlangserver request cancellation":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "extension/statusUpdate", "textDocument/publishDiagnostics",
    "$/progress",
  )

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "$/cancelRequest cancels a request that is still in flight":
    # This also pins down that the transport keeps reading while a request is
    # running: the cancellation can only be acted on if the in-flight request
    # is not holding up the connection.
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/hw/"),
        "capabilities": {"window": {"workDoneProgress": true}},
      }
    discard waitFor client.initialize(initParams)

    # A file whose project never resolves, so the handler stays parked on it
    let uri = "file:///tmp/tcancel.nim"
    ls.openFiles[uri] = NlsFileInfo(
      projectFile:
        Future[string].Raising([CancelledError, OSError, RegexError]).init("never")
    )

    let request = client.call("textDocument/definition", %positionParams(uri, 0, 0))
    waitFor sleepAsync(200)

    var id = 0'u
    for pendingId, pending in ls.pendingRequests:
      if pending.name == "textDocument/definition":
        id = pendingId
    check id != 0'u
    check ls.pendingRequests[id].state == prsOnGoing

    client.notify("$/cancelRequest", %*{"id": id.int})
    waitFor sleepAsync(200)

    check ls.pendingRequests[id].state == prsCancelled

    #The client is answered, so that it stops waiting on the request
    check request.failed
    check "-32800" in request.error.msg

  test "notifications are not tracked as pending requests":
    #They carry no id, so there is nothing to cancel or to report
    let before = ls.pendingRequests.len
    client.notify("$/setTrace", %*{"value": "verbose"})
    waitFor sleepAsync(200)
    check ls.pendingRequests.len == before

suite "Nimlangserver didOpen visibility":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "extension/statusUpdate", "textDocument/publishDiagnostics",
    "$/progress",
  )

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "didOpen makes the file visible before it yields":
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/hw/"),
        "capabilities": {"window": {"workDoneProgress": true}},
      }
    discard waitFor client.initialize(initParams)

    #didOpen cannot get past this
    ls.nimsuggestInit =
      Future[void].Raising([CancelledError, OSError]).init("parked")
    let file = "projects/hw/hw.nim"
    client.notify("textDocument/didOpen", %createDidOpenParams(file))
    waitFor sleepAsync(200)

    let uri = fixtureUri(file)
    check uri in ls.openFiles #The entry the readers look for
    check ls.openFiles[uri].fingerTable.len > 0 #The contents were stashed too

suite "Nimlangserver didOpen ordering":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "extension/statusUpdate", "textDocument/publishDiagnostics",
    "$/progress",
  )

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "a request sent right behind didOpen is answered against it":
    # The two messages go out back to back with nothing in between, so the only
    # thing that can make the request see the file is didOpen having finished
    # its synchronous part before the transport read the next message. Without
    # that, `tryGetNimsuggest` does not know the uri and the request is answered
    # with an empty result.
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/hw/"),
        "capabilities": {"window": {"workDoneProgress": true}},
      }
    discard waitFor client.initialize(initParams)

    let startup =
      Future[void].Raising([CancelledError, OSError]).init("parked")
    ls.nimsuggestInit = startup #So didOpen gets no further than registering the file
    let file = "projects/hw/hw.nim"
    let uri = fixtureUri(file)
    client.notify("textDocument/didOpen", %createDidOpenParams(file))
    let request = client.call("textDocument/definition", %positionParams(uri, 1, 6))

    # The file's project is only resolved once the startup is done, so the
    # request waits for it rather than being answered as if the file were unknown.
    waitFor sleepAsync(1.seconds)
    check not request.finished

    startup.complete()
    let locations = to(waitFor request.wait(30.seconds), seq[Location])

    check locations.len == 1
    check locations[0].uri == uri

suite "Nimlangserver request cancelled during startup":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "extension/statusUpdate", "textDocument/publishDiagnostics",
    "$/progress",
  )

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "cancelling it leaves the open file and the startup untouched":
    # The request waits on the file's `projectFile`, which waits on
    # `nimsuggestInit`; both are shared. Cancelling the request used to cancel
    # them along with it, so `didOpen` failed and every later request for the
    # file was answered with "Request cancelled".
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/hw/"),
        "capabilities": {"window": {"workDoneProgress": true}},
      }
    discard waitFor client.initialize(initParams)

    let startup =
      Future[void].Raising([CancelledError, OSError]).init("parked")
    ls.nimsuggestInit = startup
    let file = "projects/hw/hw.nim"
    let uri = fixtureUri(file)
    client.notify("textDocument/didOpen", %createDidOpenParams(file))
    let cancelled = client.call("textDocument/definition", %positionParams(uri, 1, 6))
    let id = toSeq(client.responses.keys).max
    waitFor sleepAsync(200.milliseconds)
    client.notify("$/cancelRequest", %*{"id": id})

    check waitFor cancelled.withTimeout(10.seconds)
    check not startup.cancelled
    check uri in ls.openFiles
    if uri in ls.openFiles:
      check not ls.openFiles[uri].projectFile.cancelled

    startup.complete()
    let locations = to(
      waitFor client
      .call("textDocument/definition", %positionParams(uri, 1, 6))
      .wait(30.seconds),
      seq[Location],
    )
    check locations.len == 1
    check locations[0].uri == uri

suite "Nimlangserver idle nimsuggest cleanup":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "idle nimsuggest is removed even when an open file was already evicted":
    # Regression test for #420: a URI evicted from ls.openFiles while the
    # nimsuggest still tracks it made removeIdleNimsuggests raise KeyError,
    # skipping project.stop()/projectFiles.del so the project was re-selected
    # for removal on every tick.
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/hw/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)
    let conf = NlsConfig(nimsuggestIdleTimeout: some 1000)
    ls.setWorkspaceConfiguration(% @[conf])

    let helloWorldFile = "projects/hw/hw.nim"
    let hwAbsFile = uriToPath(helloWorldFile.fixtureUri())
    client.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile))
    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {hwAbsFile}"
    )
    ls.openFiles.del(helloWorldFile.fixtureUri())

    proc sweptAway(ls: LanguageServer, projectFile: string): bool =
      waitFor ls.removeIdleNimsuggests()
      projectFile notin ls.projectFiles

    check waitUntil(ls.sweptAway(hwAbsFile), timeout = 30.seconds)

suite "Nimlangserver transport teardown":
  test "a notification sent after the client is gone is dropped":
    # Regression test for #418: an in-flight continuation resuming after the
    # teardown used to write to a torn down stdio stream and SIGSEGV inside
    # libc fwrite. The connection is what is written to now, and a late
    # notification has to be a no-op once it is gone.
    let ls = LanguageServer(serverMode: lsp, transportMode: stdio)
    ls.initServer()
    check ls.client.isNil
    ls.notify("window/showMessage", JsonString"{}")

  test "a request sent after the client is gone fails":
    # With no client to answer it, the request must fail right away rather
    # than crash or wait forever.
    let ls = LanguageServer(serverMode: lsp, transportMode: stdio)
    ls.initServer()
    check ls.client.isNil
    let res = ls.call("workspace/configuration", JsonString"{}")
    check res.failed
    expect JsonRpcError:
      discard waitFor res

suite "Nimlangserver single client":
  #`ls` is a single session - one set of open files, one set of client
  #capabilities, one workspace configuration - so the socket server serves one
  #client at a time and hangs up on anyone else. Without this, a second client
  #would silently take over `ls.client` and the first one would stop
  #receiving notifications while still having its requests answered.
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification("extension/statusUpdate")

  proc waitUntilConnected(ls: LanguageServer) {.async.} =
    while ls.client.isNil:
      await sleepAsync(10.milliseconds)

  waitFor ls.waitUntilConnected().wait(10.seconds)

  test "A second client is hung up on":
    let second = waitFor connect(resolveTAddress("localhost", cmdParams.port)[0])
    #Closed without a byte being sent, and the first client keeps the seat
    let data = waitFor second.read().wait(10.seconds)
    check data.len == 0
    check second.atEof()
    check not ls.client.isNil
    waitFor second.closeWait()

  test "The first client is still served":
    ls.initialized = true #`shutdown` is a route like any other, and checks this
    let res = waitFor client.call("shutdown", newJObject()).wait(10.seconds)
    check res.kind == JNull

suite "Nimlangserver socket session":
  #A socket session is a single connection, like a stdio one: the server stops
  #serving when its client leaves, and gives up if no client ever connects.
  test "The session ends when the client leaves":
    let cmdParams =
      CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
    let ls = main(cmdParams)
    let client = newLspSocketClient()
    waitFor client.connect("localhost", cmdParams.port)
    check waitUntil(not ls.client.isNil, 10.seconds)
    waitFor client.transport.shutdownWait()
    waitFor client.transport.closeWait()
    check waitFor ls.serve().withTimeout(10.seconds)
    check ls.serve().completed
    #No one else can connect and take over the session
    expect TransportError:
      discard waitFor connect(resolveTAddress("localhost", cmdParams.port)[0])

  test "Talking to a client that left does not crash the server":
    let cmdParams =
      CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
    let ls = main(cmdParams)
    let client = newLspSocketClient()
    waitFor client.connect("localhost", cmdParams.port)
    check waitUntil(not ls.client.isNil, 10.seconds)
    waitFor client.transport.shutdownWait()
    waitFor client.transport.closeWait()
    check waitFor ls.serve().withTimeout(10.seconds)
    check ls.client.isNil
    #The notification is dropped and the request fails, nothing is written to
    #the closed connection
    ls.notify("window/showMessage", JsonString"{}")
    let res = ls.call("workspace/configuration", JsonString"{}")
    check res.failed
    expect JsonRpcError:
      discard waitFor res

  test "The session fails when no client connects in time":
    let cmdParams =
      CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
    let ls = initLs(cmdParams, ensureStorageDir())
    ls.initServer()
    ls.registerRoutes()
    ls.startSocketServer(cmdParams.port, connectTimeout = 100.milliseconds)
    check waitFor ls.serve().withTimeout(10.seconds)
    check ls.serve().failed
    expect TransportError:
      discard waitFor connect(resolveTAddress("localhost", cmdParams.port)[0])

suite "Nimlangserver nimsuggest creation":
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
      "capabilities": {
        "window": {"workDoneProgress": true},
        "workspace":
          {"configuration": true, "inlayHint": {"refreshSupport": true}},
      },
    }
  discard waitFor client.initialize(initParams)

  let hwProjectFile = uriToPath(fixtureUri("projects/hw/hw.nim"))
  let hwUri = fixtureUri("projects/hw/hw.nim")

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "Concurrent creations for the same project are deduplicated":
    let first = ls.createOrRestartNimsuggest(hwProjectFile, hwUri)
    let second = ls.createOrRestartNimsuggest(hwProjectFile, hwUri)
    check ls.nimsuggestCreations.len == 1

    waitFor allFutures(first, second).wait(60.seconds)
    check ls.nimsuggestCreations.len == 0
    check ls.projectFiles.len == 1
    check not ls.projectFiles[hwProjectFile].process.isNil

  test "handleConfigurationChanges restarts nimsuggest before it returns":
    let previousPid = ls.projectFiles[hwProjectFile].process.pid
    let oldConfiguration = NlsConfig(
      inlayHints: some NlsInlayHintsConfig(
        exceptionHints: some NlsInlayExceptionHintsConfig(enable: some true)
      )
    )
    let newConfiguration = NlsConfig(
      inlayHints: some NlsInlayHintsConfig(
        exceptionHints: some NlsInlayExceptionHintsConfig(enable: some false)
      )
    )
    waitFor ls.handleConfigurationChanges(oldConfiguration, newConfiguration).wait(
      60.seconds
    )
    check ls.projectFiles[hwProjectFile].process.pid != previousPid
    check not ls.inlayHintsRefreshRequest.isNil

suite "Nimlangserver nimsuggest timeout restart":
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
      "capabilities": {
        "window": {"workDoneProgress": true}, "workspace": {"configuration": true}
      },
    }
  discard waitFor client.initialize(initParams)

  let hwProjectFile = uriToPath(fixtureUri("projects/hw/hw.nim"))
  let hwUri = fixtureUri("projects/hw/hw.nim")

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "The timeout restart sends the status update after the restart":
    # The timeout is read when nimsuggest starts, so only the instance started
    # here gets 1ms; the restart that replaces it gets the usual configuration
    let original = ls.workspaceConfiguration
    let tight = NlsConfig()
    tight[] = ls.getWorkspaceConfiguration()[]
    tight.timeout = some 1
    ls.workspaceConfiguration = tight
    let creation = ls.createOrRestartNimsuggest(hwProjectFile, hwUri)
    ls.workspaceConfiguration = original
    waitFor creation.wait(60.seconds)

    # A check can't finish within 1ms, so it times out and the instance is
    # replaced
    let timedOutPort = ls.projectFiles[hwProjectFile].ns.port
    discard ls.projectFiles[hwProjectFile].ns.chk(hwProjectFile)
    check waitUntil(ls.projectFiles[hwProjectFile].ns.port != timedOutPort, 60.seconds)
    let port = ls.projectFiles[hwProjectFile].ns.port
    check waitFor client.waitForNotification(
      "extension/statusUpdate",
      proc(json: JsonNode): bool =
        json{"nimsuggestInstances"}.getElems.anyIt(it{"port"}.getInt == port),
    )
