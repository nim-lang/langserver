import
  std/[options, json, os, sequtils, tables],
  json_rpc/[rpcclient],
  unittest2,
  ../[nimlangserver, ls, suggestapi, utils],
  ../protocol/[types],
  ./[lspsocketclient, testhelpers]

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

proc completes(client: LspSocketClient, uri: DocumentUri): bool =
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
    waitFor ls.shutdownNimsuggest()

  test "modules opened at the same time do not go over the cap":
    discard waitFor client.initialize(initParams())
    ls.setWorkspaceConfiguration(% @[NlsConfig(maxNimsuggestProcesses: some 1)])

    # Open all three files and ask for their nimsuggest at once, before any is
    # running. Each file would get its own nimsuggest, but the limit is 1. The
    # modules don't import each other, so only the file that got the slot is
    # served.
    let opening = files.mapIt(ls.didOpenFixture(it))
    let starting = files.mapIt(ls.tryGetNimsuggest(it.fixturePath))
    for fut in opening:
      waitFor fut
    check starting.countIt((waitFor it).isSome) == 1
    check ls.projectFiles.len == 1

suite "Idle nimsuggest instance under the cap":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newClient(cmdParams.port)

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "a file of an idle nimsuggest does not go over the cap":
    discard waitFor client.initialize(initParams())
    ls.setWorkspaceConfiguration(% @[NlsConfig(maxNimsuggestProcesses: some 2)])
    for file in [RootFile, OtherFile]:
      client.notify("textDocument/didOpen", %createDidOpenParams(file))
      check client.completes(file.fixtureUri)
    check ls.projectFiles.len == 2

    # Close the other file and stop its nimsuggest as if it had been idle for
    # too long.
    let otherPath = OtherFile.fixturePath
    let otherProject = ls.openFiles.getOrDefault(otherPath).nimsuggestProject
    let project = ls.projectFiles.getOrDefault(otherProject)
    check project != nil
    waitFor ls.didCloseFile(otherPath)
    for live in ls.projectFiles.values:
      live.lastCmdDate = some now()
    project.lastCmdDate = some(now() - initDuration(hours = 1))
    waitFor ls.removeIdleNimsuggests()
    check otherProject notin ls.projectFiles

    # A new file takes the free slot, so the limit is reached again.
    client.notify("textDocument/didOpen", %createDidOpenParams(FourthFile))
    check client.completes(FourthFile.fixtureUri)
    check ls.projectFiles.len == 2

    # No running nimsuggest knows the other file, so it gets none rather than
    # restarting its own over the limit.
    waitFor ls.didOpenFixture(OtherFile)
    check (waitFor ls.tryGetNimsuggest(otherPath)).isNone
    check ls.projectFiles.len == 2
    check otherProject notin ls.projectFiles

suite "Reusing a nimsuggest instance over the cap":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newClient(cmdParams.port)
  let projectsDir = absolutePath("tests" / "projects").Path

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "a file over the cap is served by its own project when it is live":
    discard waitFor client.initialize(
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects"),
        "capabilities": {"workspace": {"configuration": true}},
      }
    )
    ls.setWorkspaceConfiguration(% @[NlsConfig(maxNimsuggestProcesses: some 2)])
    let files = ["projects/hw/hw.nim", "projects/vendored/vendored.nim"]
    for file in files:
      waitFor ls.didOpenFixture(file)
    check ls.projectFiles.len == 2

    # The cap is reached, so both files go through the reuse. Only one of them
    # can be the first live instance, so the other one is served by its own
    # project only if the reuse prefers it.
    for file in files:
      ls.openFiles[file.fixturePath].nimsuggestProject = Path("")
    for file in files:
      check (waitFor ls.tryGetNimsuggest(file.fixturePath)).isSome
    check ls.openFiles["projects/hw/hw.nim".fixturePath].nimsuggestProject ==
      projectsDir / "hw" / "hw.nim"
    check ls.openFiles["projects/vendored/vendored.nim".fixturePath].nimsuggestProject ==
      projectsDir / "vendored" / "vendored.nim"
    check ls.projectFiles.len == 2

suite "Last used nimsuggest over the cap":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newClient(cmdParams.port)
  let projectsDir = absolutePath("tests" / "projects").Path

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "a file over the cap is served by the last used nimsuggest only if it knows it":
    discard waitFor client.initialize(
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects"),
        "capabilities": {"workspace": {"configuration": true}},
      }
    )
    # dep.nim gets a project of its own, like a file of a global package
    # opened through go-to-definition.
    ls.setWorkspaceConfiguration(
      % @[
        NlsConfig(
          maxNimsuggestProcesses: some 1,
          projectMapping: some @[
            # The regex matches the path relative to the root, which uses
            # backslashes on Windows.
            NlsNimsuggestConfig(
              projectFile: "vendored/vendor/dep/dep.nim", fileRegex: r"dep[/\\]dep"
            )
          ],
        )
      ]
    )
    let
      vendored = projectsDir / "vendored" / "vendored.nim"
      depPath = "projects/vendored/vendor/dep/dep.nim".fixturePath
      hwPath = "projects/hw/hw.nim".fixturePath
    waitFor ls.didOpenFixture("projects/vendored/vendored.nim")
    check vendored in ls.projectFiles

    # vendored.nim imports dep.nim, so its nimsuggest serves it.
    waitFor ls.didOpenFixture("projects/vendored/vendor/dep/dep.nim")
    check (waitFor ls.openFiles[depPath].projectFileWait()) ==
      projectsDir / "vendored" / "vendor" / "dep" / "dep.nim"
    check ls.openFiles[depPath].nimsuggestProject == vendored
    check ls.projectFiles.len == 1

    # hw.nim is not known by it, so it gets no nimsuggest.
    waitFor ls.didOpenFixture("projects/hw/hw.nim")
    check (waitFor ls.tryGetNimsuggest(hwPath)).isNone
    check ls.openFiles[hwPath].nimsuggestProject.len == 0
    check ls.projectFiles.len == 1
