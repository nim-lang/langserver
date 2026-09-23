import
  std/[options, json, os, sequtils, tables, strformat],
  json_rpc/[rpcclient],
  unittest2,
  ../[nimlangserver, ls, utils],
  ../protocol/[types],
  ./[lspsocketclient, testhelpers]

proc liveNimsuggests(ls: LanguageServer): int =
  ## Instances that exist or are on their way, which is what the cap has to
  ## bound: `projectFiles` alone only counts the ones that made it.
  var projects = ls.nimsuggestCreations.keys.toSeq
  for projectFile in ls.projectFiles.keys:
    if projectFile notin projects:
      projects.add projectFile
  projects.len

proc newClient(port: Port): LspSocketClient =
  result = newLspSocketClient()
  waitFor result.connect("localhost", port)
  result.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )

proc initParams(): LspInitializeParams =
  LspInitializeParams %* {
    "processId": %getCurrentProcessId(),
    "rootUri": fixtureUri("projects/twomodules"),
    "capabilities":
      {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
  }

const
  RootFile = "projects/twomodules/rootmodule.nim"
  OtherFile = "projects/twomodules/othermodule.nim"
  ThirdFile = "projects/twomodules/thirdmodule.nim"

suite "Single nimsuggest instance":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newClient(cmdParams.port)
  let otherUri = OtherFile.fixtureUri

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "a second module is served by the one running nimsuggest":
    discard waitFor client.initialize(initParams())
    ls.setWorkspaceConfiguration(% @[NlsConfig(maxNimsuggestProcesses: some 1)])

    client.notify("textDocument/didOpen", %createDidOpenParams(RootFile))
    check waitUntil(ls.projectFiles.len == 1, 60.seconds)

    client.notify("textDocument/didOpen", %createDidOpenParams(OtherFile))
    check waitUntil(otherUri in ls.openFiles, 30.seconds)

    let completion = waitFor client
      .call("textDocument/completion", %positionParams(otherUri, 4, 7))
      .wait(60.seconds)
    check completion.to(seq[CompletionItem]).mapIt(it.label).len > 0
    check ls.liveNimsuggests == 1

    let hover = waitFor client
      .call("textDocument/hover", %positionParams(otherUri, 4, 6))
      .wait(60.seconds)
    check hover.kind != JNull
    check ls.liveNimsuggests == 1

suite "Single nimsuggest instance under concurrent opens":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newClient(cmdParams.port)

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "opening three modules at once still starts a single nimsuggest":
    discard waitFor client.initialize(initParams())
    ls.setWorkspaceConfiguration(% @[NlsConfig(maxNimsuggestProcesses: some 1)])

    var peak = 0
    proc watch(): bool {.gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        peak = max(peak, ls.liveNimsuggests)
      false

    for file in [RootFile, OtherFile, ThirdFile]:
      client.notify("textDocument/didOpen", %createDidOpenParams(file))

    discard waitUntil(watch(), 30.seconds)
    checkpoint fmt"peak live nimsuggest instances: {peak}"
    check peak == 1
