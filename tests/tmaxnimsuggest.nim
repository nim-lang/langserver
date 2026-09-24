import
  std/[options, json, os, sequtils, tables],
  json_rpc/[rpcclient],
  unittest2,
  ../[nimlangserver, ls, utils],
  ../protocol/[types],
  ./lspsocketclient

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
