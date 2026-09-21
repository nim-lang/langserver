import ../[nimlangserver, ls, utils]
import ../protocol/types
import std/[options, json, os, sequtils, strutils, tables]
import chronos
import lspsocketclient
import testhelpers
import unittest2

const CallTimeout = 60.seconds

let
  entryPath = uriToPath(fixtureUri("projects/slowroot/slowroot.nim"))
  rootFile = "projects/slowroot/mappedroot.nim"
  otherFile = "projects/slowroot/other.nim"
  rootPath = uriToPath(fixtureUri(rootFile))
  otherUri = fixtureUri(otherFile)

proc mappedConfiguration(params: JsonNode): Future[JsonNode] {.async.} =
  return %*[
    {
      "projectMapping":
        [{"projectFile": "mappedroot.nim", "fileRegex": "(other|mappedroot)\\.nim$"}],
      "maxNimsuggestProcesses": 0,
      "autoCheckFile": false,
      "autoCheckProject": false,
      "nimsuggestIdleTimeout": 1,
    }
  ]

proc defaultConfiguration(params: JsonNode): Future[JsonNode] {.async.} =
  return %*[{"autoCheckFile": false, "autoCheckProject": false}]

proc answerNull(params: JsonNode): Future[JsonNode] {.async.} =
  newJNull()

proc startSlowRootServer(configuration: Rpc): (LanguageServer, LspSocketClient) =
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  client.registerNotification(
    "window/showMessage", "extension/statusUpdate", "textDocument/publishDiagnostics",
    "$/progress",
  )
  client.register("workspace/configuration", configuration)
  client.register("client/registerCapability", answerNull)
  client.register("window/workDoneProgress/create", answerNull)

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
  doAssert waitUntil(ls.workspaceConfigurationReady.finished)
  (ls, client)

proc documentSymbols(client: LspSocketClient, file: string): Future[JsonNode] =
  client.call(
    "textDocument/documentSymbol", %*{"textDocument": {"uri": fixtureUri(file)}}
  )

suite "Nimsuggest startup for a slow mapped root":
  let (ls, client) = startSlowRootServer(mappedConfiguration)

  proc initializedMessages(): int =
    client.calls["window/showMessage"].countIt(
      it["message"].getStr == "Nimsuggest initialized for " & rootPath
    )

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "files opened during startup share a single nimsuggest for their root":
    check not ls.nimsuggestInit.finished
    client.notify("textDocument/didOpen", %createDidOpenParams(otherFile))
    client.notify("textDocument/didOpen", %createDidOpenParams(rootFile))

    check waitUntil(initializedMessages() >= 1, CallTimeout)
    check not waitUntil(initializedMessages() > 1, 3.seconds)
    check ls.failTable.getOrDefault(rootPath, 0) == 0
    check rootPath in ls.projectFiles

    waitFor sleepAsync(100.milliseconds)
    waitFor ls.removeIdleNimsuggests()
    check rootPath in ls.projectFiles

    let symbols = waitFor client.documentSymbols(otherFile).wait(CallTimeout)
    check symbols.getElems.anyIt(it["name"].getStr == "other")

suite "Requests during startup":
  let (ls, client) = startSlowRootServer(mappedConfiguration)

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "a request behind didOpen waits for the file instead of answering empty":
    check not ls.nimsuggestInit.finished
    client.notify("textDocument/didOpen", %createDidOpenParams(otherFile))
    check waitUntil(otherUri in ls.openFiles, 1.seconds)
    let symbols = waitFor client.documentSymbols(otherFile).wait(CallTimeout)
    check symbols.getElems.anyIt(it["name"].getStr == "other")

suite "Project resolution during startup":
  let (ls, client) = startSlowRootServer(defaultConfiguration)

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "a file opened during startup uses the startup nimsuggest":
    check not ls.nimsuggestInit.finished
    client.notify("textDocument/didOpen", %createDidOpenParams(otherFile))

    check waitUntil(
      otherUri in ls.openFiles and ls.openFiles[otherUri].projectFile.finished and
        ls.nimsuggestInit.finished,
      CallTimeout,
    )
    check not waitUntil(ls.projectFiles.len > 1, 8.seconds)
    check (waitFor ls.openFiles[otherUri].waitProjectFile()) == entryPath
    check toSeq(ls.projectFiles.keys) == @[entryPath]

suite "Shared project futures":
  test "joining project resolution does not cancel the shared future":
    let projectFile =
      Future[string].Raising([CancelledError, OSError, RegexError]).init("projectFile")
    let file = NlsFileInfo(projectFile: projectFile)
    let waiter = file.waitProjectFile()
    waiter.cancelSoon()
    waitFor sleepAsync(100.milliseconds)
    check not projectFile.cancelled
    projectFile.complete("root.nim")
    check waiter.cancelled
