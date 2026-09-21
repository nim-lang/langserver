import
  std/[options, json, os, sequtils, strformat, tables],
  chronos,
  chronos/asyncproc,
  unittest2,
  ../[nimlangserver, ls, utils],
  ../protocol/[enums, types],
  ./lspsocketclient,
  ./testhelpers

const CallTimeout = 30.seconds

var holdConfiguration: Future[void] #when set, the client delays its answer

var editorConfiguration = %*[
  {
    "projectMapping": [],
    "buildOnSave": false,
    "buildCommand": "c",
    "lintOnSave": false,
    "provider": "lsp",
    "useNimsuggestCheck": false,
    "logNimsuggest": false,
    "nimsuggestRestartTimeout": 60,
    "inlayHints": {
      "typeHints": {"enable": true},
      "parameterHints": {"enable": true},
      "exceptionHints": {"enable": true, "hintStringLeft": "!", "hintStringRight": ""},
    },
    "notificationVerbosity": "info",
    "transportMode": "stdio",
    "formatOnSave": false,
    "maxNimsuggestProcesses": 0,
    "nimsuggestIdleTimeout": 120000,
  }
]

suite "Workspace configuration parsing":
  test "a configuration we cannot use never parses to nil":
    # NlsConfig is a ref and every caller reads a field out of it, so none of
    # these may come back as nil.
    for conf in [
      %*{"settings": {"nim": newJNull()}},
      %*{"settings": {}},
      %*{"settings": newJNull()},
      newJArray(),
      newJNull(),
    ]:
      checkpoint $conf
      check not parseWorkspaceConfiguration(conf).isNil

suite "Waiting for the workspace configuration":
  proc newLs(): LanguageServer =
    initLs(
      CommandLineParams(mode: some ServerMode.lsp, transport: some TransportMode.socket),
      ensureStorageDir(),
    )

  let pushed = % @[NlsConfig(nimsuggestIdleTimeout: some 1234)]

  test "a waiter that starts before the first configuration is let through":
    # The readiness future is completed once and never replaced, so a wait that
    # started before the client answered cannot be left behind by it.
    let ls = newLs()
    let waiting = ls.getAndWaitForWorkspaceConfiguration()
    check not waiting.finished

    ls.setWorkspaceConfiguration(pushed)
    check (waitFor waiting).nimsuggestIdleTimeout == some 1234

  test "cancelling one waiter leaves the configuration for everyone else":
    # chronos cancels the future being awaited, and the future is shared, so the
    # wait is shielded with join(): cancelling detaches that waiter alone.
    let ls = newLs()
    let
      abandoned = ls.getAndWaitForWorkspaceConfiguration()
      other = ls.getAndWaitForWorkspaceConfiguration()
    waitFor abandoned.cancelAndWait()
    check abandoned.cancelled

    ls.setWorkspaceConfiguration(pushed)
    check (waitFor other).nimsuggestIdleTimeout == some 1234
    check ls.getWorkspaceConfiguration().nimsuggestIdleTimeout == some 1234

suite "LSP configuration pushed by the client":
  # A client that doesn't support workspace/configuration pushes its settings
  # with didChangeConfiguration instead.
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  client.registerNotification(
    "window/showMessage", "extension/statusUpdate", "textDocument/publishDiagnostics",
    "$/progress",
  )
  waitFor client.connect("localhost", cmdParams.port)

  discard waitFor client.initialize(
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities": {"window": {"workDoneProgress": false}},
    }
  )
  client.notify("initialized", newJObject())
  check waitUntil(ls.workspaceConfigurationReady.finished)

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "a null nim section keeps the server serving":
    # The client has no settings for us. The configuration used to parse to nil
    # and stay in ls.workspaceConfiguration, so the next read of it took the
    # server down: the idle nimsuggest sweep every tick, or any request.
    client.notify(
      "workspace/didChangeConfiguration", %*{"settings": {"nim": newJNull()}}
    )
    # the notification is handled before the request that follows it
    let status = to(
      waitFor client.call("extension/status", newJObject()).wait(CallTimeout),
      NimLangServerStatus,
    )
    check status.version == LSPVersion

    check not ls.getWorkspaceConfiguration().isNil

suite "LSP configuration pulled from the client":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  client.registerNotification(
    "window/showMessage", "extension/statusUpdate", "textDocument/publishDiagnostics",
    "$/progress",
  )

  proc answerConfiguration(params: JsonNode): Future[JsonNode] {.async.} =
    {.cast(gcsafe).}:
      if holdConfiguration != nil: #let a test hold the answer back
        await holdConfiguration
      return editorConfiguration

  proc answerNull(params: JsonNode): Future[JsonNode] {.async.} =
    newJNull()

  client.registerRequest("workspace/configuration", answerConfiguration)
  client.registerRequest("client/registerCapability", answerNull)
  client.registerRequest("window/workDoneProgress/create", answerNull)
  client.registerRequest("workspace/inlayHint/refresh", answerNull)

  waitFor client.connect("localhost", cmdParams.port)

  let initParams =
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities": {
        "window": {"workDoneProgress": true},
        "workspace": {
          "configuration": true,
          "didChangeConfiguration": {"dynamicRegistration": true},
          "inlayHint": {"refreshSupport": true},
        },
      },
    }
  discard waitFor client.initialize(initParams)
  client.notify("initialized", newJObject())
  check waitUntil(ls.workspaceConfigurationReady.finished)

  let
    helloWorldFile = "projects/hw/hw.nim"
    helloWorldUri = fixtureUri(helloWorldFile)
  client.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile))
  check waitFor client.waitForNotificationMessage(
    fmt"Nimsuggest initialized for {uriToPath(helloWorldUri)}"
  )

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "the server registers workspace/didChangeConfiguration dynamically":
    let registrations = client.calls["client/registerCapability"]
    check registrations.len > 0

    var registeredDidChangeConfiguration = false
    for call in registrations:
      for registration in call{"registrations"}:
        if registration{"method"}.getStr == "workspace/didChangeConfiguration":
          registeredDidChangeConfiguration = true
    check registeredDidChangeConfiguration

  test "the server pulls the configuration and the answer reaches it":
    check client.calls["workspace/configuration"].len > 0
    var askedForNimSection = false
    for item in client.calls["workspace/configuration"][0]{"items"}:
      if item{"section"}.getStr == "nim":
        askedForNimSection = true
    check askedForNimSection
    check ls.workspaceConfigurationReady.finished

    let conf = ls.getWorkspaceConfiguration()
    check conf.nimsuggestIdleTimeout == some 120000
    check conf.logNimsuggest == some false

  test "the pulled configuration is what nimsuggest was started with":
    let status = to(
      waitFor client.call("extension/status", newJObject()).wait(CallTimeout),
      NimLangServerStatus,
    )
    check status.nimsuggestInstances.len == 1
    check status.nimsuggestInstances[0].capabilities.anyIt($it == "exceptionInlayHints")

  test "a project check reports progress to the client":
    proc checkIdle(ls: LanguageServer, projectFile: string): bool =
      if ls.checkInProgress or projectFile notin ls.projectFiles:
        return false
      let ns = ls.projectFiles[projectFile].ns
      ns != nil and not ns.checkProjectInProgress

    check waitUntil(ls.checkIdle(uriToPath(helloWorldUri)), timeout = 60.seconds)

    let createdBefore = client.calls["window/workDoneProgress/create"].len

    client.notify(
      "textDocument/didSave",
      %*{
        "textDocument": {"uri": helloWorldUri},
        "text": readFile("tests" / helloWorldFile),
      },
    )

    check waitUntil(
      client.calls["window/workDoneProgress/create"].len > createdBefore,
      timeout = 30.seconds,
    )

    let token = client.calls["window/workDoneProgress/create"][^1]{"token"}.getStr
    check token.len > 0
    proc reportedAgainst(client: LspSocketClient, token: string): bool =
      for progress in client.calls["$/progress"]:
        if progress{"token"}.getStr == token:
          return true
      false

    check waitUntil(client.reportedAgainst(token), timeout = 30.seconds)

  test "the configuration we have stays in place while a new one is pulled":
    # A pull used to put a pending future back in place, so for the length of
    # the round trip every reader got the defaults instead of the settings the
    # client had already given us.
    let pulledBefore = client.calls["workspace/configuration"].len
    holdConfiguration = Future[void].init("holdConfiguration")
    editorConfiguration[0]["nimsuggestIdleTimeout"] = %60000
    defer:
      holdConfiguration = nil
      editorConfiguration[0]["nimsuggestIdleTimeout"] = %120000

    client.notify("workspace/didChangeConfiguration", %*{"settings": newJNull()})
    check waitUntil(client.calls["workspace/configuration"].len > pulledBefore)
    check ls.getWorkspaceConfiguration().nimsuggestIdleTimeout == some 120000

    holdConfiguration.complete()
    check waitUntil(ls.getWorkspaceConfiguration().nimsuggestIdleTimeout == some 60000)

  test "toggling the exception inlay hints restarts nimsuggest and asks for a refresh":
    let projectFile = uriToPath(helloWorldUri)
    check projectFile in ls.projectFiles
    let
      pidBefore = ls.projectFiles[projectFile].process.pid
      refreshesBefore = client.calls["workspace/inlayHint/refresh"].len

    editorConfiguration[0]["inlayHints"]["exceptionHints"]["enable"] = %false
    client.notify("workspace/didChangeConfiguration", %*{"settings": newJNull()})

    check waitUntil(client.calls["workspace/inlayHint/refresh"].len > refreshesBefore)

    check waitUntil(
      projectFile in ls.projectFiles and
        ls.projectFiles[projectFile].process.pid != pidBefore,
      timeout = 30.seconds,
    )
