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

proc startServer(root = "projects/multimodules"): (LanguageServer, LspSocketClient) =
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
      "rootUri": fixtureUri(root),
      "capabilities":
        {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
    }
  )
  # The check scheduled after each edit would reopen an idle file on its own,
  # and so would a project check still running when the nimsuggest is stopped.
  ls.setWorkspaceConfiguration(
    % @[NlsConfig(autoCheckFile: some false, autoCheckProject: some false)]
  )
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
    waitFor ls.shutdownNimsuggest()

  test "the next request keeps the edits":
    client.openRootFile()
    client.editRootFile()
    check waitUntil(ls.openFiles.getOrDefault(uri).changed)

    let diagnostics = client.diagnosticsFor(uri)
    ls.stopAsIdle()
    check uri in ls.openFiles
    # Stopping the nimsuggest is not a close: the file must not be checked
    # against the disk, which clears its diagnostics.
    check not waitUntil(client.diagnosticsFor(uri) > diagnostics, 3.seconds)
    check ls.projectFiles.len == 0

    check "zeta" in client.completionLabels(6, 7)

suite "Idle file edited after its nimsuggest was stopped":
  let (ls, client) = startServer()
  let uri = RootFile.fixtureUri

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "the next request applies the edits":
    client.openRootFile()
    ls.stopAsIdle()
    check uri in ls.openFiles

    client.editRootFile()
    check waitUntil(ls.openFiles.getOrDefault(uri).changed)
    check ls.projectFiles.len == 0

    check "zeta" in client.completionLabels(6, 7)

suite "Idle nimsuggest shared by several files":
  let (ls, client) = startServer()
  let otherUri = OtherFile.fixtureUri

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "every file it served stays open and is served again":
    ls.setWorkspaceConfiguration(
      % @[
        NlsConfig(
          maxNimsuggestProcesses: some 1,
          autoCheckFile: some false,
          autoCheckProject: some false,
        )
      ]
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
    check RootFile.fixtureUri in ls.openFiles
    check otherUri in ls.openFiles
    check ls.projectFiles.len == 0

    let completion = waitFor client
      .call("textDocument/completion", %positionParams(otherUri, 4, 7))
      .wait(60.seconds)
    check completion.len > 0
    check ls.projectFiles.len == 1

suite "Idle nimsuggest of a nimble package":
  let (ls, client) = startServer("projects")
  let vendored = absolutePath("tests" / "projects" / "vendored" / "vendored.nim")

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "it is stopped like any other":
    waitFor ls.didOpenFile(
      createDidOpenParams("projects/vendored/vendored.nim").textDocument
    )
    check (waitFor ls.tryGetNimsuggest("projects/vendored/vendored.nim".fixtureUri)).isSome
    # The package's own module is one of its entry points, which used to be
    # kept running however long they were idle.
    let nimbleFile = absolutePath("tests" / "projects" / "vendored" / "vendored.nimble")
    check vendored in ls.nimblePackages[nimbleFile].entryPoints
    check vendored in ls.projectFiles
    ls.stopAsIdle()
    check vendored notin ls.projectFiles

suite "Idle nimsuggest of a mapped project":
  let (ls, client) = startServer()
  let rootPath = RootFile.fixtureUri.uriToPath

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "it is stopped like any other":
    ls.setWorkspaceConfiguration(
      % @[
        NlsConfig(
          autoCheckFile: some false,
          autoCheckProject: some false,
          projectMapping: some @[
            NlsNimsuggestConfig(projectFile: "rootmodule.nim", fileRegex: "othermodule")
          ],
        )
      ]
    )
    waitFor ls.didOpenFile(createDidOpenParams(OtherFile).textDocument)
    check (waitFor ls.tryGetNimsuggest(OtherFile.fixtureUri)).isSome
    # Mapped projects used to be kept running however long they were idle.
    check ls.openFiles[OtherFile.fixtureUri].nimsuggestProject == rootPath
    ls.stopAsIdle()
    check rootPath notin ls.projectFiles

suite "Closed file shared with another":
  let (ls, client) = startServer()
  let otherUri = OtherFile.fixtureUri

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "a closed file is no longer listed by its nimsuggest":
    # The other file is mapped to the root file's project, so both are served
    # by the same nimsuggest.
    ls.setWorkspaceConfiguration(
      % @[
        NlsConfig(
          autoCheckFile: some false,
          projectMapping: some @[
            NlsNimsuggestConfig(projectFile: "rootmodule.nim", fileRegex: "othermodule")
          ],
        )
      ]
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

suite "File closed after its nimsuggest was stopped":
  let (ls, client) = startServer()
  let uri = RootFile.fixtureUri

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "a nimsuggest is not started for it":
    client.openRootFile()
    ls.stopAsIdle()
    check uri in ls.openFiles

    client.notify("textDocument/didClose", %*{"textDocument": {"uri": uri}})
    check waitUntil(uri notin ls.openFiles)

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

suite "File closed with unsaved edits":
  let (ls, client) = startServer()
  let uri = RootFile.fixtureUri

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "its diagnostics are for the file on disk":
    ls.setWorkspaceConfiguration(% @[NlsConfig(autoCheckFile: some true)])
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

suite "File edited while it is checked":
  let (ls, client) = startServer()
  let uri = RootFile.fixtureUri

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "the outdated diagnostics are not published":
    ls.setWorkspaceConfiguration(
      % @[NlsConfig(autoCheckFile: some false, autoCheckProject: some false)]
    )
    client.openRootFile()
    let published = client.diagnosticsFor(uri)

    let checking = ls.checkFile(ls.openFiles[uri])
    # A call, unlike a notification, returns once the edit is applied.
    discard waitFor client
      .call(
        "textDocument/didChange",
        %*{
          "textDocument": {"uri": uri, "version": 2},
          "contentChanges":
            [{"text": readFile("tests" / RootFile) & "echo notDefinedAnywhere\n"}],
        },
      )
      .wait(60.seconds)
    waitFor checking
    # The reply comes after every notification sent before it.
    check client.completionLabels(4, 7).len > 0
    check client.diagnosticsFor(uri) == published

    waitFor ls.checkFile(ls.openFiles[uri])
    check client.completionLabels(4, 7).len > 0
    check client.diagnosticsFor(uri) == published + 1
    check client.lastDiagnosticsFor(uri).len > 0

suite "Failed nimsuggest with no other to fall back to":
  let (ls, client) = startServer()
  let rootProject = RootFile.fixtureUri.uriToPath

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

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

suite "Failed nimsuggest while others run":
  let (ls, client) = startServer()

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "the file is not served by another nimsuggest":
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

    # The other file's project failed too many times. The others don't know
    # the file, so none of them can serve it.
    let otherUri = OtherFile.fixtureUri
    ls.failTable[otherUri.uriToPath] = 10

    check (waitFor ls.tryGetNimsuggest(otherUri)).isNone
    check ls.openFiles.getOrDefault(otherUri).nimsuggestProject == ""
    check ls.projectFiles.len == 4
