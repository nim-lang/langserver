import ../[nimlangserver, ls, lstransports, utils]
import ../protocol/[enums, types]
import std/[options, json, os, jsonutils, sequtils, strutils, sugar, strformat]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient
import unittest2

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
  client.notify("initialized", newJObject())

  let
    helloWorldFile = "projects/hw/hw.nim"
    helloWorldUri = fixtureUri(helloWorldFile)
  client.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile))
  check waitFor client.waitForNotificationMessage(
    fmt"Nimsuggest initialized for {uriToPath(helloWorldUri)}"
  )
  client.notify(
    "textDocument/didSave",
    %*{
      "textDocument": {"uri": helloWorldUri},
      "text": readFile("tests" / helloWorldFile),
    },
  )

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "Opening a file with a type error publishes diagnostics for it":
    proc hasAnyDiagnostic(
        json: JsonNode
    ): bool {.gcsafe, raises: [CatchableError].} =
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
