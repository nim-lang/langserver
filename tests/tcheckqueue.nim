import
  std/[options, json, os, strformat, tables],
  chronos,
  unittest2,
  ../[nimlangserver, ls, utils],
  ../protocol/[types],
  ./lspsocketclient,
  ./testhelpers

# The server checks one project at a time. A project opened while another is being
# checked must be checked after it, not skipped, and checking one project must not clear
# the diagnostics another project's check published.

suite "Project checks, two projects at once":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  client.registerNotification(
    "window/showMessage", "extension/statusUpdate", "textDocument/publishDiagnostics",
    "$/progress",
  )

  proc answerConfiguration(params: JsonNode): Future[JsonNode] {.async.} =
    # a nimsuggest each: with the default of one, both files would share a project
    return %*[{"maxNimsuggestProcesses": 0}]

  proc answerNull(params: JsonNode): Future[JsonNode] {.async.} =
    newJNull()

  client.registerRequest("workspace/configuration", answerConfiguration)
  client.registerRequest("client/registerCapability", answerNull)
  client.registerRequest("window/workDoneProgress/create", answerNull)

  waitFor client.connect("localhost", cmdParams.port)
  discard waitFor client.initialize(
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/twoprojects/"),
      "capabilities": {"workspace": {"configuration": true}},
    }
  )
  client.notify("initialized", newJObject())
  check waitUntil(ls.workspaceConfigurationReady.finished)

  let
    firstFile = "projects/twoprojects/first/first.nim"
    secondFile = "projects/twoprojects/second/second.nim"
    firstUri = fixtureUri(firstFile)
    secondUri = fixtureUri(secondFile)
  client.notify("textDocument/didOpen", %createDidOpenParams(firstFile))
  client.notify("textDocument/didOpen", %createDidOpenParams(secondFile))

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  proc hasErrorFor(uri: string): auto =
    proc(json: JsonNode): bool {.gcsafe, raises: [CatchableError].} =
      {.cast(gcsafe).}:
        json{"uri"}.getStr == uri and json{"diagnostics"}.len > 0

  test "both projects are checked":
    check waitFor client.waitForNotification(
      "textDocument/publishDiagnostics", hasErrorFor(firstUri)
    )
    check waitFor client.waitForNotification(
      "textDocument/publishDiagnostics", hasErrorFor(secondUri)
    )

  test "checking one project keeps the other's diagnostics":
    # the last diagnostics each file got are still its error
    for uri in [firstUri, secondUri]:
      var last = newJNull()
      for call in client.calls["textDocument/publishDiagnostics"]:
        if call{"uri"}.getStr == uri:
          last = call
      checkpoint fmt"{uri}: {last}"
      check last{"diagnostics"}.getElems.len > 0
