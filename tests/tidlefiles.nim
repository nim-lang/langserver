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
  ThirdFile = "projects/multimodules/thirdmodule.nim"
  FourthFile = "projects/multimodules/fourthmodule.nim"
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
  # The check scheduled after each edit would reopen an idle file on its own.
  ls.setWorkspaceConfiguration(% @[NlsConfig(autoCheckFile: some false)])
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

proc diagnosticsFor(client: LspSocketClient, uri: string): int =
  client.calls.getOrDefault("textDocument/publishDiagnostics").countIt(
    it["uri"].getStr == uri
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

    let diagnostics = client.diagnosticsFor(uri)
    ls.stopAsIdle()
    check uri in ls.idleOpenFiles
    # Going idle is not a close: the file must not be checked against the
    # stopped nimsuggest, which clears its diagnostics.
    check not waitUntil(client.diagnosticsFor(uri) > diagnostics, 3.seconds)
    check ls.projectFiles.len == 0

    check "zeta" in client.completionLabels(6, 7)

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
    check ls.projectFiles.len == 0

    check "zeta" in client.completionLabels(6, 7)

suite "Idle nimsuggest shared by several files":
  let (ls, client) = startServer()
  let otherUri = OtherFile.fixtureUri

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "every file it served goes idle with it":
    ls.setWorkspaceConfiguration(
      % @[NlsConfig(maxNimsuggestProcesses: some 1, autoCheckFile: some false)]
    )
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
    check RootFile.fixtureUri in ls.idleOpenFiles
    check otherUri in ls.idleOpenFiles
    check otherUri notin ls.openFiles
    check ls.projectFiles.len == 0

suite "Restarted nimsuggest shared by several files":
  let (ls, client) = startServer()
  let otherUri = OtherFile.fixtureUri

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "every file it served still goes idle with it":
    ls.setWorkspaceConfiguration(
      % @[NlsConfig(maxNimsuggestProcesses: some 1, autoCheckFile: some false)]
    )
    client.openRootFile()
    client.notify("textDocument/didOpen", %createDidOpenParams(OtherFile))
    check waitUntil(otherUri in ls.openFiles)
    discard waitFor client
      .call("textDocument/completion", %positionParams(otherUri, 4, 7))
      .wait(60.seconds)
    check ls.projectFiles.len == 1

    # Restarted like after a timeout or an error: the new nimsuggest has to
    # keep serving, and tracking, the other file too.
    let rootProject = RootFile.fixtureUri.uriToPath
    waitFor ls.createOrRestartNimsuggest(rootProject, RootFile.fixtureUri)
    check ls.projectFiles.len == 1

    ls.stopAsIdle()
    check RootFile.fixtureUri in ls.idleOpenFiles
    check otherUri in ls.idleOpenFiles
    check otherUri notin ls.openFiles
    check ls.projectFiles.len == 0

suite "Closed file shared with another":
  let (ls, client) = startServer()
  let otherUri = OtherFile.fixtureUri

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "a closed file is no longer listed by its nimsuggest":
    ls.setWorkspaceConfiguration(
      % @[NlsConfig(maxNimsuggestProcesses: some 1, autoCheckFile: some false)]
    )
    client.openRootFile()
    client.notify("textDocument/didOpen", %createDidOpenParams(OtherFile))
    check waitUntil(otherUri in ls.openFiles)
    discard waitFor client
      .call("textDocument/completion", %positionParams(otherUri, 4, 7))
      .wait(60.seconds)
    check ls.getLspStatus().nimsuggestInstances.len == 1
    check otherUri in ls.getLspStatus().nimsuggestInstances[0].openFiles

    client.notify("textDocument/didClose", %*{"textDocument": {"uri": otherUri}})
    check waitUntil(otherUri notin ls.openFiles)
    check otherUri notin ls.getLspStatus().nimsuggestInstances[0].openFiles
    check RootFile.fixtureUri in ls.getLspStatus().nimsuggestInstances[0].openFiles

suite "Idle file closed by the editor":
  let (ls, client) = startServer()
  let uri = RootFile.fixtureUri

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "a closed idle file is not reopened":
    client.openRootFile()
    ls.stopAsIdle()
    check uri in ls.idleOpenFiles

    client.notify("textDocument/didClose", %*{"textDocument": {"uri": uri}})
    check waitUntil(uri notin ls.idleOpenFiles)

    # A late request for the closed file must not bring it back or start a
    # nimsuggest for it.
    check client.completionLabels(4, 7).len == 0
    check uri notin ls.openFiles
    check ls.projectFiles.len == 0

proc lastDiagnosticsFor(client: LspSocketClient, uri: string): JsonNode =
  result = newJArray()
  for params in client.calls.getOrDefault("textDocument/publishDiagnostics"):
    if params["uri"].getStr == uri:
      result = params["diagnostics"]

suite "File served by another nimsuggest":
  let (ls, client) = startServer()
  let otherUri = OtherFile.fixtureUri

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "it goes idle with the nimsuggest that served it":
    ls.setWorkspaceConfiguration(
      % @[NlsConfig(maxNimsuggestProcesses: some 2, autoCheckFile: some false)]
    )
    client.openRootFile()
    client.notify("textDocument/didOpen", %createDidOpenParams(OtherFile))
    check waitUntil(otherUri in ls.openFiles)
    discard waitFor client
      .call("textDocument/completion", %positionParams(otherUri, 4, 7))
      .wait(60.seconds)
    let rootProject = RootFile.fixtureUri.uriToPath
    let otherProject = OtherFile.fixtureUri.uriToPath
    check ls.projectFiles.len == 2
    check otherProject in ls.projectFiles

    # Too many failures on its own nimsuggest, so the other file is served by
    # the root file's one from now on.
    ls.failTable[otherProject] = 10
    discard waitFor client
      .call("textDocument/completion", %positionParams(otherUri, 4, 7))
      .wait(60.seconds)

    for project in ls.projectFiles.values:
      project.lastCmdDate = some now()
    ls.projectFiles[rootProject].lastCmdDate = some(now() - initDuration(hours = 1))
    waitFor ls.removeIdleNimsuggests()
    check rootProject notin ls.projectFiles
    check otherUri in ls.idleOpenFiles
    check otherUri notin ls.openFiles

suite "File closed with unsaved edits":
  let (ls, client) = startServer()
  let uri = RootFile.fixtureUri

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "its diagnostics are for the file on disk":
    ls.setWorkspaceConfiguration(% @[NlsConfig()])
    client.openRootFile()
    client.notify(
      "textDocument/didChange",
      %*{
        "textDocument": {"uri": uri, "version": 2},
        "contentChanges":
          [{"text": readFile("tests" / RootFile) & "echo notDefinedAnywhere\n"}],
      },
    )
    check waitUntil(client.lastDiagnosticsFor(uri).len > 0, 30.seconds)

    # The edit is discarded, so the error it added must go away.
    let published = client.diagnosticsFor(uri)
    client.notify("textDocument/didClose", %*{"textDocument": {"uri": uri}})
    check waitUntil(client.diagnosticsFor(uri) > published, 30.seconds)
    check client.lastDiagnosticsFor(uri).len == 0

suite "Failed nimsuggest with no other to fall back to":
  let (ls, client) = startServer()
  let rootProject = RootFile.fixtureUri.uriToPath

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "it is not started again":
    client.openRootFile()
    check ls.projectFiles.len == 1

    # Failed too many times and is gone, like after restarts that did not
    # succeed.
    ls.projectFiles[rootProject].stop()
    ls.projectFiles.del(rootProject)
    ls.failTable[rootProject] = 10

    # There is nothing to wait for, so the request must not be retried.
    let requested = Moment.now()
    check client.completionLabels(4, 7).len == 0
    check Moment.now() - requested < 5.seconds
    check ls.projectFiles.len == 0

suite "Failover with other failing nimsuggests":
  let (ls, client) = startServer()

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "the file is served by the one that is not failing":
    ls.setWorkspaceConfiguration(
      % @[NlsConfig(maxNimsuggestProcesses: some 0, autoCheckFile: some false)]
    )
    let files = [RootFile, OtherFile, ThirdFile, FourthFile]
    for file in files:
      client.notify("textDocument/didOpen", %createDidOpenParams(file))
      check waitUntil(file.fixtureUri in ls.openFiles)
      discard waitFor client
        .call("textDocument/completion", %positionParams(file.fixtureUri, 4, 7))
        .wait(60.seconds)
    check ls.projectFiles.len == 4

    # Every project but the fourth one failed too many times.
    for file in [RootFile, OtherFile, ThirdFile]:
      ls.failTable[file.fixtureUri.uriToPath] = 10

    let otherUri = OtherFile.fixtureUri
    discard waitFor client
      .call("textDocument/completion", %positionParams(otherUri, 4, 7))
      .wait(60.seconds)
    check ls.openFiles.getOrDefault(otherUri).nimsuggestProject ==
      FourthFile.fixtureUri.uriToPath
