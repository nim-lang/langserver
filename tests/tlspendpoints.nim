import ../[nimlangserver, ls, lstransports, utils]
import ../protocol/[enums, types]
import std/[options, json, os, jsonutils, sequtils, strutils, sugar, strformat]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient
import testhelpers
import unittest2

const CallTimeout = 30.seconds

proc callTimeout(
    client: LspSocketClient, name: string, params: JsonNode
): JsonNode =
  waitFor client.call(name, params).wait(CallTimeout)

suite "LSP endpoints":
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
      "capabilities":
        {"window": {"workDoneProgress": false}, "workspace": {"configuration": true}},
    }
  discard waitFor client.initialize(initParams)
  client.notify("initialized", newJObject())

  let
    helloWorldFile = "projects/hw/hw.nim"
    helloWorldUri = fixtureUri(helloWorldFile)
  client.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile))
  check waitFor client.waitForNotificationMessage(
    fmt"Nimsuggest initialized for {uriToPath(helloWorldUri)}"
  )

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "textDocument/typeDefinition answers for a typed symbol":
    let locations = to(
      client.callTimeout(
        "textDocument/typeDefinition", %positionParams(helloWorldUri, 8, 2)
      ),
      seq[Location],
    )
    for location in locations:
      check location.uri.len > 0

  test "textDocument/documentSymbol lists the symbols of the file":
    let params = DocumentSymbolParams %* {"textDocument": {"uri": helloWorldUri}}
    let symbols = to(
      client.callTimeout("textDocument/documentSymbol", %params), seq[SymbolInformation]
    )
    check symbols.len > 0
    check symbols.anyIt(it.name == "helloProc")
    check symbols.anyIt(it.name == "Obj")
    for symbol in symbols:
      check symbol.location.uri == helloWorldUri

  test "textDocument/documentHighlight answers for a symbol":
    let highlights = to(
      client.callTimeout(
        "textDocument/documentHighlight", %positionParams(helloWorldUri, 3, 0)
      ),
      seq[DocumentHighlight],
    )
    for highlight in highlights:
      check highlight.range.start.line >= 0

  test "textDocument/signatureHelp answers inside a call":
    let params =
      SignatureHelpParams %* {
        "textDocument": {"uri": helloWorldUri},
        "position": {"line": 1, "character": 11},
        "context": {"triggerKind": 1, "isRetrigger": false},
      }
    let response = client.callTimeout("textDocument/signatureHelp", %params)
    check response.kind in {JObject, JNull}

  test "textDocument/inlayHint answers for a range":
    let params =
      InlayHintParams %* {
        "textDocument": {"uri": helloWorldUri},
        "range":
          {"start": {"line": 0, "character": 0}, "end": {"line": 10, "character": 0}},
      }
    let hints =
      to(client.callTimeout("textDocument/inlayHint", %params), seq[InlayHint])
    for hint in hints:
      check hint.label.len > 0

  test "textDocument/codeAction answers for a range":
    let params =
      CodeActionParams %* {
        "textDocument": {"uri": helloWorldUri},
        "range":
          {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}},
        "context": {"diagnostics": []},
      }
    let actions =
      to(client.callTimeout("textDocument/codeAction", %params), seq[CodeAction])
    for action in actions:
      check action.title.len > 0

  test "workspace/symbol answers a query":
    let params = WorkspaceSymbolParams %* {"query": "bbb"}
    let symbols =
      to(client.callTimeout("workspace/symbol", %params), seq[SymbolInformation])
    for symbol in symbols:
      check symbol.name.len > 0

  test "extension/status reports the running nimsuggest instances":
    let status =
      to(client.callTimeout("extension/status", newJObject()), NimLangServerStatus)
    check status.version == LSPVersion
    check status.nimsuggestInstances.len > 0
    check status.nimsuggestInstances.anyIt(it.projectFile.endsWith("hw.nim"))

  test "extension/capabilities lists the extension capabilities":
    let capabilities =
      to(client.callTimeout("extension/capabilities", newJObject()), seq[string])
    check capabilities.len > 0
    check "RestartSuggest" in capabilities

  test "$/setTrace is accepted and the server keeps serving":
    defer:
      client.notify("$/setTrace", %*{"value": "off"})

    client.notify("$/setTrace", %*{"value": "verbose"})
    let status =
      to(client.callTimeout("extension/status", newJObject()), NimLangServerStatus)
    check status.version == LSPVersion

  test "textDocument/didSave is accepted and the server keeps serving":
    client.notify(
      "textDocument/didSave",
      %*{
        "textDocument": {"uri": helloWorldUri},
        "text": readFile("tests" / helloWorldFile),
      },
    )
    let status =
      to(client.callTimeout("extension/status", newJObject()), NimLangServerStatus)
    check status.version == LSPVersion

  test "textDocument/willSaveWaitUntil answers with edits":
    let params =
      WillSaveTextDocumentParams %* {"textDocument": {"uri": helloWorldUri}, "reason": 1}
    let edits =
      to(client.callTimeout("textDocument/willSaveWaitUntil", %params), seq[TextEdit])
    for edit in edits:
      check edit.newText.len >= 0

  test "workspace/executeCommand runs a project check":
    let params =
      ExecuteCommandParams %* {
        "command": CHECK_PROJECT_COMMAND,
        "arguments": [%uriToPath(helloWorldUri)],
      }
    discard client.callTimeout("workspace/executeCommand", %params)
    let status =
      to(client.callTimeout("extension/status", newJObject()), NimLangServerStatus)
    check status.version == LSPVersion

  test "textDocument/didClose removes the file from the open set":
    let other = "projects/hw/useRoot.nim"
    let otherUri = fixtureUri(other)
    client.notify("textDocument/didOpen", %createDidOpenParams(other))
    check waitUntil(otherUri in ls.openFiles)

    client.notify("textDocument/didClose", %*{"textDocument": {"uri": otherUri}})
    check waitUntil(otherUri notin ls.openFiles)

  test "A request for a file that was never opened is answered":
    let unopened = fixtureUri("projects/hw/willCrash.nim")
    discard client.callTimeout(
      "textDocument/documentSymbol", %*{"textDocument": {"uri": unopened}}
    )
    let status =
      to(client.callTimeout("extension/status", newJObject()), NimLangServerStatus)
    check status.version == LSPVersion

  test "A position past the end of the file is answered, not crashed on":
    discard client.callTimeout(
      "textDocument/hover", %positionParams(helloWorldUri, 9999, 9999)
    )
    let status =
      to(client.callTimeout("extension/status", newJObject()), NimLangServerStatus)
    check status.version == LSPVersion

  test "Concurrent requests are all answered":
    var pending: seq[Future[JsonNode]]
    for i in 0 ..< 10:
      pending.add client.call("extension/status", newJObject())
    waitFor allFutures(pending).wait(CallTimeout)
    for fut in pending:
      check fut.read().kind == JObject

  test "An unknown notification leaves the server serving":
    client.notify("textDocument/thisMethodDoesNotExist", newJObject())
    let status =
      to(client.callTimeout("extension/status", newJObject()), NimLangServerStatus)
    check status.version == LSPVersion

  test "extension/macroExpand expands a macro application":
    let params =
      ExpandTextDocumentPositionParams %* {
        "textDocument": {"uri": helloWorldUri},
        "position": {"line": 21, "character": 0},
      }
    let expanded =
      to(client.callTimeout("extension/macroExpand", %params), ExpandResult)
    check expanded.content.contains("helloProc")
    check expanded.content.contains("Hello")

  test "workspace/didChangeConfiguration is accepted and the server keeps serving":
    let previousConfiguration = ls.workspaceConfiguration
    defer:
      ls.workspaceConfiguration = previousConfiguration

    client.notify(
      "workspace/didChangeConfiguration", %*{"settings": {"nim": {"nimsuggestIdleTimeout": 120000}}}
    )
    let status =
      to(client.callTimeout("extension/status", newJObject()), NimLangServerStatus)
    check status.version == LSPVersion

  test "extension/cancelTest reports nothing to cancel when no test is running":
    let res =
      to(client.callTimeout("extension/cancelTest", newJObject()), CancelTestResult)
    check res.cancelled == false

  test "A request whose handler throws is answered with a JSON-RPC error":
    var raised = false
    try:
      discard client.callTimeout(
        "textDocument/hover", %*{"position": {"line": 0, "character": 0}}
      )
    except LspResponseError as ex:
      raised = true
      check ex.error{"code"}.getInt == -32603
      check ex.error{"message"}.getStr.len > 0
    check raised

  test "The server keeps serving after a handler has thrown":
    let status =
      to(client.callTimeout("extension/status", newJObject()), NimLangServerStatus)
    check status.version == LSPVersion

  test "$/cancelRequest cancels an in-flight request":
    proc cancellableCompletion(ls: LanguageServer, found: var uint): bool =
      for id, request in ls.pendingRequests:
        if request.name == "textDocument/completion" and request.state == prsOnGoing and
            request.request != nil:
          found = id
          return true
      false

    let pending =
      client.call("textDocument/completion", %positionParams(helloWorldUri, 2, 0))
    var target = 0'u
    check waitUntil(ls.cancellableCompletion(target))

    defer:
      pending.cancelSoon()

    client.notify("$/cancelRequest", %*{"id": target.int})
    check waitUntil(ls.pendingRequests[target].state == prsCancelled)
    check pending.finished == false

  test "textDocument/formatting returns an edit for the whole file":
    if findExe("nph") == "":
      skip()
    else:
      let
        plainFile = "projects/hw/useRoot.nim"
        plainUri = fixtureUri(plainFile)
      defer:
        client.notify("textDocument/didClose", %*{"textDocument": {"uri": plainUri}})
        discard waitUntil(plainUri notin ls.openFiles)

      client.notify("textDocument/didOpen", %createDidOpenParams(plainFile))
      check waitUntil(plainUri in ls.openFiles)
      client.notify(
        "textDocument/didChange",
        %*{
          "textDocument": {"uri": plainUri, "version": 2},
          "contentChanges": [{"text": readFile("tests" / plainFile)}],
        },
      )
      check waitUntil(
        plainUri in ls.openFiles and ls.openFiles[plainUri].changed
      )

      let params =
        DocumentFormattingParams %* {
          "textDocument": {"uri": plainUri},
          "options": {"tabSize": 2, "insertSpaces": true},
        }
      let edits =
        to(client.callTimeout("textDocument/formatting", %params), seq[TextEdit])
      check edits.len == 1
      check edits[0].newText.contains("root.nim")

  test "a definition request on a non ascii identifier resolves to its declaration":
    let locations = to(
      client.callTimeout("textDocument/definition", %positionParams(helloWorldUri, 1, 6)),
      seq[Location],
    )
    check locations.len == 1
    check locations[0].uri.contains("hw.nim")
    check locations[0].range.start.line == 0

  test "documentSymbol reports a non ascii symbol at a UTF-16 offset":
    let params = DocumentSymbolParams %* {"textDocument": {"uri": helloWorldUri}}
    let symbols = to(
      client.callTimeout("textDocument/documentSymbol", %params), seq[SymbolInformation]
    )
    let nonAscii = symbols.filterIt(it.name == "a안녕")
    check nonAscii.len == 1
    check nonAscii[0].location.range.start.line == 0
    check nonAscii[0].location.range.start.character == 5

  test "documentHighlight reports UTF-16 columns for a non ascii identifier":
    let highlights = to(
      client.callTimeout(
        "textDocument/documentHighlight", %positionParams(helloWorldUri, 1, 6)
      ),
      seq[DocumentHighlight],
    )
    let onCallLine = highlights.filterIt(it.range.start.line == 1)
    check onCallLine.len > 0
    check onCallLine.anyIt(it.range.start.character == 6)
    check not onCallLine.anyIt(it.range.start.character == 10)

  test "didChange replaces the whole document and later requests see it":
    let original = readFile("tests" / helloWorldFile)
    defer:
      client.notify(
        "textDocument/didChange",
        %*{
          "textDocument": {"uri": helloWorldUri, "version": 99},
          "contentChanges": [{"text": original}],
        },
      )
      discard waitUntil(
        not readFile(ls.uriStorageLocation(helloWorldUri)).contains("addedByDidChange")
      )

    client.notify(
      "textDocument/didChange",
      %*{
        "textDocument": {"uri": helloWorldUri, "version": 3},
        "contentChanges": [{"text": original & "\nproc addedByDidChange*() = discard\n"}],
      },
    )
    check waitUntil(
      readFile(ls.uriStorageLocation(helloWorldUri)).contains("addedByDidChange")
    )

    let params = DocumentSymbolParams %* {"textDocument": {"uri": helloWorldUri}}
    let symbols = to(
      client.callTimeout("textDocument/documentSymbol", %params), seq[SymbolInformation]
    )
    check symbols.anyIt(it.name == "addedByDidChange")
    check not readFile("tests" / helloWorldFile).contains("addedByDidChange")

  test "the suite leaves the server in the state it started in":
    check ls.openFiles.len == 1
    check helloWorldUri in ls.openFiles
    check ls.projectFiles.len == 1

    let stash = ls.uriStorageLocation(helloWorldUri)
    if fileExists(stash):
      check readFile(stash).strip == readFile("tests" / helloWorldFile).strip

suite "LSP socket transport with more than one client":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)

  let clientA = newLspSocketClient()
  clientA.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )
  waitFor clientA.connect("localhost", cmdParams.port)
  discard waitFor clientA.initialize(
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities": {"window": {"workDoneProgress": false}},
    }
  )

  test "the only client is answered":
    let status =
      to(clientA.callTimeout("extension/status", newJObject()), NimLangServerStatus)
    check status.version == LSPVersion

  test "a second client can connect and is served":
    let clientB = newLspSocketClient()
    clientB.registerNotification(
      "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
      "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
    )
    waitFor clientB.connect("localhost", cmdParams.port)

    let status =
      to(clientB.callTimeout("extension/status", newJObject()), NimLangServerStatus)
    check status.version == LSPVersion
