import ../[nimlangserver, ls, utils]
import ../protocol/types
import std/[options, json, os, sequtils, strutils, tables]
import chronos
import lspsocketclient
import testhelpers
import unittest2

const CallTimeout = 60.seconds

suite "Nimsuggest startup for a slow project root":
  # Reproduces the Constantine issue (#436, #453) without Constantine: a nimble
  # project whose files are mapped through `projectMapping` to a root other than
  # the nimble entry point, both slow to compile. `didOpen` waits for the
  # server's startup (`nimsuggestInit`), so files opened meanwhile all resume
  # together once it is done. A root is only registered in `projectFiles` after
  # nimsuggest's initial compilation, so each of them used to start its own
  # nimsuggest for the mapped root, and the last one stopped the others.
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  client.registerNotification(
    "window/showMessage", "extension/statusUpdate", "textDocument/publishDiagnostics",
    "$/progress",
  )

  proc answerConfiguration(params: JsonNode): Future[JsonNode] {.async.} =
    return %*[
      {
        "projectMapping":
          [{"projectFile": "mappedroot.nim", "fileRegex": "(other|mappedroot)\\.nim$"}],
        "maxNimsuggestProcesses": 0,
        "autoCheckFile": false,
        "autoCheckProject": false,
      }
    ]

  proc answerNull(params: JsonNode): Future[JsonNode] {.async.} =
    newJNull()

  client.registerRequest("workspace/configuration", answerConfiguration)
  client.registerRequest("client/registerCapability", answerNull)
  client.registerRequest("window/workDoneProgress/create", answerNull)

  waitFor client.connect("localhost", cmdParams.port)
  discard waitFor client.initialize(
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/slowroot/"),
      "capabilities":
        {"window": {"workDoneProgress": false}, "workspace": {"configuration": true}},
    }
  )
  client.notify("initialized", newJObject())
  check waitUntil(ls.workspaceConfiguration.finished)

  let
    rootFile = "projects/slowroot/mappedroot.nim"
    otherFile = "projects/slowroot/other.nim"
    rootPath = uriToPath(fixtureUri(rootFile))

  proc initializedMessages(): int =
    client.calls["window/showMessage"].countIt(
      it["message"].getStr == "Nimsuggest initialized for " & rootPath
    )

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "files opened during startup share a single nimsuggest for their root":
    # Sent back to back while the entry point is still compiling, so both opens
    # are parked on `nimsuggestInit` and resume at the same time.
    check not ls.nimsuggestInit.finished
    client.notify("textDocument/didOpen", %createDidOpenParams(otherFile))
    client.notify("textDocument/didOpen", %createDidOpenParams(rootFile))

    check waitUntil(initializedMessages() >= 1, timeout = CallTimeout)
    # A duplicate would either be reported as initialized too, or be stopped by
    # the next one and show up as a failure for the root.
    check not waitUntil(initializedMessages() > 1, timeout = 3.seconds)
    check ls.failTable.getOrDefault(rootPath, 0) == 0
    check rootPath in ls.projectFiles

    # The nimsuggest that is left is the one serving the files.
    check waitUntil(fixtureUri(otherFile) in ls.openFiles, timeout = CallTimeout)
    let symbols = waitFor client
      .call(
        "textDocument/documentSymbol",
        %*{"textDocument": {"uri": fixtureUri(otherFile)}},
      )
      .wait(CallTimeout)
    check symbols.kind == JArray
    check symbols.getElems.anyIt(it["name"].getStr == "other")
