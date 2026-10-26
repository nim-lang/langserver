import
  std/[options, json, os, sequtils, sugar, strformat],
  json_rpc/[rpcclient],
  unittest2,
  ../[nimlangserver, ls, utils],
  ../protocol/[types],
  ./[lspsocketclient, testhelpers]

suite "nimble setup":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "extension/statusUpdate",
    "textDocument/publishDiagnostics", "$/progress",
  )
  let testProjectDir = absolutePath "tests" / "projects" / "testproject"

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "should pick `testproject.nim` as the main file and provide suggestions":
    let entryPoint = testProjectDir / "src" / "testproject.nim"
    createNimbleProject(testProjectDir)
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testproject"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)
    ls.setWorkspaceConfiguration(% @[NlsConfig()])

    let completionParams =
      CompletionParams %* {
        "position": {"line": 7, "character": 0},
        "textDocument": {"uri": pathToUri(entryPoint)},
      }
    client.notify(
      "textDocument/didOpen",
      %createDidOpenParams("projects/testproject/src/testproject.nim"),
    )
    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {entryPoint}"
    )
    check waitFor client.waitForNotification(
      "window/showMessage",
      (json: JsonNode) =>
        json["message"].to(string) == &"Opening {pathToUri(entryPoint)}",
    )

    #We need to make two calls (ns issue)
    discard client.call("textDocument/completion", %completionParams).waitFor
    let completionList = client
      .call("textDocument/completion", %completionParams).waitFor
      .to(seq[CompletionItem])
      .mapIt(it.label)
    check completionList.len > 0

  test "`submodule.nim` should not be part of the nimble project file":
    let submodule = testProjectDir / "src" / "testproject" / "submodule.nim"
    client.notify(
      "textDocument/didOpen",
      %createDidOpenParams("projects/testproject/src/testproject/submodule.nim"),
    )

    check waitFor client.waitForNotification(
      "window/showMessage",
      (json: JsonNode) => json["message"].to(string) == &"Opening {pathToUri(submodule)}",
    )

    check ls.projectFiles.len == 1

  test "the nimble package reports its source dir and main file":
    let nimbleFile = testProjectDir / "testproject.nimble"
    let package = waitFor ls.nimblePackage(nimbleFile)
    check package.dir == testProjectDir
    check package.sourceDir == testProjectDir / "src"
    check package.projectFile == testProjectDir / "src" / "testproject.nim"
    check package.projectFile in package.entryPoints

suite "Project Mapping":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "extension/statusUpdate",
    "textDocument/publishDiagnostics", "$/progress",
  )
  let projectsDir = absolutePath "tests" / "projects"

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "should use projectMapping fileRegex to find project file":
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)
    let configurationParams =
      @[NlsConfig(projectMapping: some @[NlsNimsuggestConfig(fileRegex: "nonimble*")])]
    let nonimbleProject = projectsDir / "nonimbleproject.nim"
    ls.setWorkspaceConfiguration(%configurationParams)

    let projectFile = waitFor getProjectFile(nonimbleProject, ls)
    let matchingMsg = fmt"RegEx matched `nonimble*` for file `{nonimbleProject}`"

    check waitFor client.waitForNotification(
      "window/showMessage",
      proc(json: JsonNode): bool =
        json["message"].getStr == matchingMsg,
    )
    let expectedProjectFile = nonimbleProject

    check projectFile == expectedProjectFile

suite "Nimble packages":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )
  let projectsDir = absolutePath "tests" / "projects"
  discard waitFor client.initialize(
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects"),
      "capabilities": {"workspace": {"configuration": true}},
    }
  )
  ls.setWorkspaceConfiguration(% @[NlsConfig()])

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "a file of a vendored package belongs to the package that vendors it":
    let dep = projectsDir / "vendored" / "vendor" / "dep" / "dep.nim"
    check (waitFor getProjectFile(dep, ls)) == projectsDir / "vendored" / "vendored.nim"
    check projectsDir / "vendored" / "vendor" / "dep" / "dep.nimble" notin
      ls.nimblePackages

  test "a folder with several nimble files is not a package":
    let sub = projectsDir / "twonimbles" / "sub" / "sub.nim"
    let other = projectsDir / "twonimbles" / "sub" / "other.nim"
    check (waitFor getProjectFile(other, ls)) == sub
    # the entry point is in the package's folder, not in the workspace's
    check sub in ls.entryPoints

  test "a package is dumped once":
    let nimbleFile = projectsDir / "vendored" / "vendored.nimble"
    let load = ls.nimblePackageLoads.getOrDefault(nimbleFile)
    check load != nil
    discard waitFor getProjectFile(projectsDir / "vendored" / "vendored.nim", ls)
    check ls.nimblePackageLoads.getOrDefault(nimbleFile) == load

  test "a file of a known package keeps resolving to it":
    let dep = projectsDir / "vendored" / "vendor" / "dep" / "dep.nim"
    check projectsDir / "vendored" / "vendored.nimble" in ls.nimblePackageLoads
    check (waitFor getProjectFile(dep, ls)) == projectsDir / "vendored" / "vendored.nim"

  test "nimsuggest runs in the folder of the file's package":
    let dep = projectsDir / "vendored" / "vendor" / "dep" / "dep.nim"
    check (waitFor ls.getWorkingDir(dep)) == projectsDir / "vendored"

  test "a file outside of any package runs in the workspace":
    let hw = projectsDir / "hw" / "hw.nim"
    check (waitFor ls.getWorkingDir(hw)) == ls.lspInitializeParams.getRootPath

  test "nim comes from the Nim of the file's package":
    let dep = projectsDir / "vendored" / "vendor" / "dep" / "dep.nim"
    let package = ls.nimblePackages[projectsDir / "vendored" / "vendored.nimble"]
    let nimPath = waitFor ls.getNimPath(NlsConfig(), dep)
    if package.nimDir.isSome and package.nimDir.get.dirExists:
      check nimPath == some(package.nimDir.get / "nim")
    else:
      check nimPath == some(findExe "nim")
