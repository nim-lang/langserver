import
  std/[options, json, os, strformat],
  json_rpc/[rpcclient],
  unittest2,
  ../[nimlangserver, ls, suggestapi, utils],
  ../protocol/[types],
  ./[lspsocketclient, testhelpers]

const CallTimeout = 30.seconds

suite "LSP diagnostics":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )
  waitFor client.connect("localhost", cmdParams.port)

  let initParams =
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities": {"window": {"workDoneProgress": false}},
    }
  let initializeResult = waitFor client.initialize(initParams)
  ls.setWorkspaceConfiguration(% @[NlsConfig()])
  client.notify("initialized", newJObject())

  let
    helloWorldFile = "projects/hw/hw.nim"
    helloWorldUri = fixtureUri(helloWorldFile)
  client.openFile(helloWorldFile)
  check waitFor client.waitForNotificationMessage(
    fmt"Nimsuggest initialized for {uriToPath(helloWorldUri)}"
  )
  client.notify(
    "textDocument/didSave",
    %*{
      "textDocument": {"uri": helloWorldUri}, "text": readFile("tests" / helloWorldFile)
    },
  )

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "Opening a file with a type error publishes diagnostics for it":
    proc hasAnyDiagnostic(json: JsonNode): bool {.gcsafe, raises: [CatchableError].} =
      {.cast(gcsafe).}:
        json{"uri"}.getStr == helloWorldUri and json{"diagnostics"}.len > 0

    check waitFor client.waitForNotification(
      "textDocument/publishDiagnostics", hasAnyDiagnostic
    )

  test "The published diagnostic carries a uri, a range and a message":
    proc isWellFormed(json: JsonNode): bool {.gcsafe, raises: [CatchableError].} =
      {.cast(gcsafe).}:
        if json{"uri"}.getStr != helloWorldUri:
          return false
      for diagnostic in json{"diagnostics"}:
        let
          message = diagnostic{"message"}.getStr
          line = diagnostic{"range"}{"start"}{"line"}
        if message.len > 0 and line.kind == JInt and line.getInt >= 0:
          return true
      false

    check waitFor client.waitForNotification(
      "textDocument/publishDiagnostics", isWellFormed
    )

  test "A diagnostic reports its severity and source":
    proc hasSeverity(json: JsonNode): bool {.gcsafe, raises: [CatchableError].} =
      for diagnostic in json{"diagnostics"}:
        if diagnostic{"severity"}.kind == JInt and diagnostic{"source"}.getStr.len > 0:
          return true
      false

    check waitFor client.waitForNotification(
      "textDocument/publishDiagnostics", hasSeverity
    )

  test "The server keeps serving after diagnostics have been published":
    let status = to(
      waitFor client.call("extension/status", newJObject()).wait(CallTimeout),
      NimLangServerStatus,
    )
    check status.version == LSPVersion

  test "initialize advertises the providers whose routes are registered":
    let capabilities = initializeResult.capabilities
    check capabilities.textDocumentSync.isSome
    check not capabilities.completionProvider.isNil
    check capabilities.hoverProvider.get(false)
    check capabilities.definitionProvider.get(false)
    check capabilities.referencesProvider.get(false)
    check capabilities.documentSymbolProvider.get(false)
    check capabilities.workspaceSymbolProvider.get(false)
    check capabilities.documentHighlightProvider.get(false)
    check capabilities.typeDefinitionProvider.get(false)
    check capabilities.declarationProvider.get(false)

  test "initialize advertises the extension commands it can execute":
    let provider = initializeResult.capabilities.executeCommandProvider
    check provider.isSome
    let commands = provider.get.commands.get(@[])
    check RESTART_COMMAND in commands
    check CHECK_PROJECT_COMMAND in commands
    check RECOMPILE_COMMAND in commands

  test "The server answers extension/capabilities consistently with its routes":
    let capabilities = to(
      waitFor client.call("extension/capabilities", newJObject()).wait(CallTimeout),
      seq[string],
    )
    for capability in LspExtensionCapability:
      check $capability in capabilities

suite "LSP project check command":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )
  waitFor client.connect("localhost", cmdParams.port)
  discard waitFor client.initialize(
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/mcpproject/"),
      "capabilities": {"window": {"workDoneProgress": false}},
    }
  )
  ls.setWorkspaceConfiguration(% @[NlsConfig(useNimCheck: some false)])

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "checks a project whose project file is not open":
    let
      projectFile =
        absolutePath("tests" / "projects" / "mcpproject" / "src" / "mcpproject.nim")
      errmoduleUri = fixtureUri("projects/mcpproject/src/mcpproject/errmodule.nim")

    # Only a test file is open. It belongs to the package, so the nimsuggest
    # runs for the package's project file, which the editor never opened.
    client.openFile("projects/mcpproject/tests/test1.nim")
    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {projectFile}"
    )
    check projectFile.pathToUri notin ls.openFiles
    let project = ls.projectFiles[projectFile]
    check waitUntil(
      not ls.checkInProgress and not project.ns.checkProjectInProgress, 30.seconds
    )

    # errmodule.nim has a type error, so a project check publishes for it.
    proc errmodulePublishes(): int =
      for params in client.calls["textDocument/publishDiagnostics"]:
        if params{"uri"}.getStr == errmoduleUri:
          inc result

    let published = errmodulePublishes()
    discard waitFor client
      .call(
        "workspace/executeCommand",
        %*{"command": CHECK_PROJECT_COMMAND, "arguments": [projectFile]},
      )
      .wait(CallTimeout)
    check waitUntil(errmodulePublishes() > published, 30.seconds)
