import
  std/[options, json, os, sequtils, sets, tables],
  json_rpc/[rpcclient],
  unittest2,
  ../[nimlangserver, ls, suggestapi, utils],
  ../protocol/[types],
  ./lspsocketclient

from std/times import now, initDuration, `-`

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
    "rootUri": fixtureUri("projects/multimodules"),
    "capabilities":
      {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
  }

const
  RootFile = "projects/multimodules/rootmodule.nim"
  OtherFile = "projects/multimodules/othermodule.nim"
  ThirdFile = "projects/multimodules/thirdmodule.nim"
  FourthFile = "projects/multimodules/fourthmodule.nim"

proc completes(client: LspSocketClient, uri: string): bool =
  let completion = waitFor client
    .call("textDocument/completion", %positionParams(uri, 4, 7))
    .wait(60.seconds)
  completion.to(seq[CompletionItem]).len > 0

suite "Single nimsuggest instance under concurrent project resolution":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newClient(cmdParams.port)
  let files = [RootFile, OtherFile, ThirdFile]

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "modules resolved at the same time share one project":
    discard waitFor client.initialize(initParams())
    ls.setWorkspaceConfiguration(% @[NlsConfig(maxNimsuggestProcesses: some 1)])

    # Started together, so every call is past the cap check before any of them
    # has picked a project. Each module is its own project when guessed alone.
    let resolving = files.mapIt(getProjectFile(it.fixtureUri.uriToPath, ls))
    var projects: seq[string]
    for fut in resolving:
      projects.add waitFor fut
    check projects.deduplicate.len == 1

    for file in files:
      client.notify("textDocument/didOpen", %createDidOpenParams(file))
    for file in files:
      check client.completes(file.fixtureUri)
    check ls.projectFiles.len == 1

suite "Stopped nimsuggest instance under the cap":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newClient(cmdParams.port)

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "a file left on a stopped project does not restart it past the cap":
    discard waitFor client.initialize(initParams())
    ls.setWorkspaceConfiguration(% @[NlsConfig(maxNimsuggestProcesses: some 2)])
    for file in [RootFile, OtherFile, ThirdFile]:
      client.notify("textDocument/didOpen", %createDidOpenParams(file))
      check client.completes(file.fixtureUri)
    check ls.projectFiles.len == 2

    # The third module reused one of the two, which doesn't track it in its
    # `openFiles`, so stopping it as idle leaves the module bound to it.
    let thirdUri = ThirdFile.fixtureUri
    let reused = waitFor ls.openFiles.getOrDefault(thirdUri).waitProjectFile()
    let project = ls.projectFiles.getOrDefault(reused)
    check project != nil
    check thirdUri notin project.ns.openFiles
    for live in ls.projectFiles.values:
      live.lastCmdDate = some now()
    project.lastCmdDate = some(now() - initDuration(hours = 1))
    waitFor ls.removeIdleNimsuggests()
    check reused notin ls.projectFiles
    check thirdUri in ls.openFiles

    client.notify("textDocument/didOpen", %createDidOpenParams(FourthFile))
    check client.completes(FourthFile.fixtureUri)
    check ls.projectFiles.len == 2

    check client.completes(thirdUri)
    check ls.projectFiles.len == 2
    check reused notin ls.projectFiles
