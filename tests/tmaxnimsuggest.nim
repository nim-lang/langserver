import
  std/[options, json, os, sequtils, tables],
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

suite "Single nimsuggest instance under concurrent opens":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newClient(cmdParams.port)
  let files = [RootFile, OtherFile, ThirdFile]

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "modules opened at the same time share one nimsuggest":
    discard waitFor client.initialize(initParams())
    ls.setWorkspaceConfiguration(% @[NlsConfig(maxNimsuggestProcesses: some 1)])

    # Open all three files at once, before any nimsuggest is running. Each file
    # would get its own nimsuggest, but the limit is 1, so they must share one.
    let opening = files.mapIt(ls.didOpenFile(createDidOpenParams(it).textDocument))
    for fut in opening:
      waitFor fut
    check ls.projectFiles.len == 1

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

    # The limit was reached, so the third file uses one of the two running
    # nimsuggests. Stop that nimsuggest as if it had been idle for too long.
    # Only the file that started it gets closed; the third file stays open and
    # still points to the stopped one.
    let thirdUri = ThirdFile.fixtureUri
    let reused = waitFor ls.openFiles.getOrDefault(thirdUri).waitProjectFile()
    let project = ls.projectFiles.getOrDefault(reused)
    check project != nil
    for live in ls.projectFiles.values:
      live.lastCmdDate = some now()
    project.lastCmdDate = some(now() - initDuration(hours = 1))
    waitFor ls.removeIdleNimsuggests()
    check reused notin ls.projectFiles
    check thirdUri in ls.openFiles

    # A new file takes the free slot, so the limit is reached again.
    client.notify("textDocument/didOpen", %createDidOpenParams(FourthFile))
    check client.completes(FourthFile.fixtureUri)
    check ls.projectFiles.len == 2

    # Using the third file again must not restart the stopped nimsuggest.
    check client.completes(thirdUri)
    check ls.projectFiles.len == 2
    check reused notin ls.projectFiles
