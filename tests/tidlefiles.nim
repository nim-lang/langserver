import
  std/[options, json, os, sequtils, tables],
  json_rpc/[rpcclient],
  unittest2,
  ../[nimlangserver, ls, suggestapi, utils],
  ../protocol/[types],
  ./[lspsocketclient, testhelpers]

from std/times import now, initDuration, `-`

const
  RootFile = "projects/multimodules/rootmodule.nim"
  OtherFile = "projects/multimodules/othermodule.nim"
  # Adds `zeta` to the module and leaves the cursor after `ze` on line 6.
  EditedText =
    """proc alpha*(x: int): int =
  ## Alpha doc.
  x + 1

proc zeta(): int = 2

echo ze
"""

proc startServer(): (LanguageServer, LspSocketClient) =
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )
  discard waitFor client.initialize(
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/multimodules"),
      "capabilities":
        {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
    }
  )
  ls.setWorkspaceConfiguration(% @[NlsConfig()])
  (ls, client)

proc completionLabels(client: LspSocketClient, line, character: int): seq[string] =
  let completion = waitFor client
    .call(
      "textDocument/completion",
      %positionParams(RootFile.fixtureUri, line, character),
    )
    .wait(60.seconds)
  completion.to(seq[CompletionItem]).mapIt(it.label)

proc openRootFile(client: LspSocketClient) =
  client.notify("textDocument/didOpen", %createDidOpenParams(RootFile))
  check client.completionLabels(4, 7).len > 0

proc editRootFile(client: LspSocketClient) =
  client.notify(
    "textDocument/didChange",
    %*{
      "textDocument": {"uri": RootFile.fixtureUri, "version": 2},
      "contentChanges": [{"text": EditedText}],
    },
  )

proc stopAsIdle(ls: LanguageServer) =
  for project in ls.projectFiles.values:
    project.lastCmdDate = some(now() - initDuration(hours = 1))
  waitFor ls.removeIdleNimsuggests()

suite "Idle file edited before its nimsuggest was stopped":
  let (ls, client) = startServer()
  let uri = RootFile.fixtureUri

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "reopening keeps the edits":
    client.openRootFile()
    client.editRootFile()
    check waitUntil(ls.openFiles.getOrDefault(uri).changed)

    ls.stopAsIdle()
    check uri in ls.idleOpenFiles

    check "zeta" in client.completionLabels(6, 7)
    check ls.openFiles.getOrDefault(uri).changed

suite "Idle file edited after its nimsuggest was stopped":
  let (ls, client) = startServer()
  let uri = RootFile.fixtureUri

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "reopening applies the edits":
    client.openRootFile()
    ls.stopAsIdle()
    check uri in ls.idleOpenFiles

    client.editRootFile()
    check waitUntil(ls.idleOpenFiles.getOrDefault(uri).changed)

    check "zeta" in client.completionLabels(6, 7)
    check ls.openFiles.getOrDefault(uri).changed

suite "Idle nimsuggest shared by several files":
  let (ls, client) = startServer()
  let otherUri = OtherFile.fixtureUri

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "every file it served goes idle with it":
    ls.setWorkspaceConfiguration(% @[NlsConfig(maxNimsuggestProcesses: some 1)])
    client.openRootFile()
    # The limit is 1, so the other file uses the nimsuggest started for the
    # root file.
    client.notify("textDocument/didOpen", %createDidOpenParams(OtherFile))
    check waitUntil(otherUri in ls.openFiles)
    discard waitFor client
      .call("textDocument/completion", %positionParams(otherUri, 4, 7))
      .wait(60.seconds)
    check ls.projectFiles.len == 1

    ls.stopAsIdle()
    check ls.projectFiles.len == 0
    check RootFile.fixtureUri in ls.idleOpenFiles
    check otherUri in ls.idleOpenFiles
    check otherUri notin ls.openFiles
