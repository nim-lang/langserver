import ../[nimlangserver, ls, utils]
import ../protocol/[enums, types]
import std/[options, json, os, sequtils, strformat, tables]
import chronos
import chronos/asyncproc
import lspsocketclient
import testhelpers
import unittest2

const CallTimeout = 30.seconds

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
  check waitUntil(ls.workspaceConfiguration.finished)

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
    check ls.workspaceConfiguration.finished

    let conf = waitFor ls.getWorkspaceConfiguration()
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
      ns.finished and not ns.read().checkProjectInProgress

    check waitUntil(
      ls.checkIdle(uriToPath(helloWorldUri)), timeout = 60.seconds
    )

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
