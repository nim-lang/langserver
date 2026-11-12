import
  std/[options, json, os, sequtils, sugar, strformat, times],
  chronos,
  chronos/asyncproc,
  json_rpc/[rpcclient],
  unittest2,
  ../[nimlangserver, ls, suggestapi, utils],
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
  let testProjectDir = absolutePath("tests" / "projects" / "testproject").Path

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "should pick `testproject.nim` as the main file and provide suggestions":
    let entryPoint = testProjectDir / "src" / "testproject.nim"
    createNimbleProject(testProjectDir.string)
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
    client.openFile("projects/testproject/src/testproject.nim")
    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {entryPoint}"
    )
    check waitFor client.waitForNotification(
      "window/showMessage",
      (json: JsonNode) =>
        json["message"].to(string) == &"Opening {entryPoint}",
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
      (json: JsonNode) => json["message"].to(string) == &"Opening {submodule}",
    )

    check ls.projectFiles.len == 1

  test "the nimble package reports its source dir and main file":
    let entryPoint = testProjectDir / "src" / "testproject.nim"
    discard waitFor ls.getProjectFile(entryPoint)
    let package = ls.nimblePackages[testProjectDir / "testproject.nimble"]
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

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "should use projectMapping fileRegex to find project file":
    # Outside the langserver package, so the file belongs to no package.
    let rootDir = getTempDir().Path / "nimlangserver-project-mapping"
    createDir(rootDir.string)
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": pathToUri(rootDir),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)
    let configurationParams =
      @[NlsConfig(projectMapping: some @[NlsNimsuggestConfig(fileRegex: "nonimble*")])]
    let nonimbleProject = rootDir / "nonimbleproject.nim"
    ls.setWorkspaceConfiguration(%configurationParams)

    let projectFile = waitFor ls.getProjectFile(nonimbleProject)
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
  let projectsDir = absolutePath("tests" / "projects").Path
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
    check (waitFor ls.getProjectFile(dep)) == projectsDir / "vendored" / "vendored.nim"
    check projectsDir / "vendored" / "vendor" / "dep" / "dep.nimble" notin
      ls.nimblePackages

  test "a folder with several nimble files is not a package":
    let sub = projectsDir / "twonimbles" / "sub" / "sub.nim"
    let other = projectsDir / "twonimbles" / "sub" / "other.nim"
    check (waitFor ls.getProjectFile(other)) == sub
    # the entry point is in the package's folder, not in the workspace's
    check sub in
      ls.nimblePackages[projectsDir / "twonimbles" / "sub" / "sub.nimble"].entryPoints

  test "a package is dumped once":
    let nimbleFile = projectsDir / "vendored" / "vendored.nimble"
    let load = ls.nimblePackageLoads.getOrDefault(nimbleFile)
    check load != nil
    discard waitFor ls.getProjectFile(projectsDir / "vendored" / "vendored.nim")
    check ls.nimblePackageLoads.getOrDefault(nimbleFile) == load

  test "a failed nimble dump is retried once the nimble file changes":
    let
      packageDir = projectsDir / "brokennimble"
      nimbleFile = packageDir / "broken.nimble"
      mainFile = packageDir / "src" / "broken.nim"
    createDir((packageDir / "src").string)
    writeFile(mainFile.string, "echo 1\n")
    writeFile(nimbleFile.string, "srcDir = \"src\"\nthis is not nim(\n")

    discard waitFor ls.getProjectFile(mainFile)
    check ls.nimblePackages[nimbleFile].dumpFailed
    check (waitFor ls.getWorkingDir(mainFile)) == packageDir

    let failedLoad = ls.nimblePackageLoads[nimbleFile]
    discard waitFor ls.getProjectFile(mainFile)
    check ls.nimblePackageLoads[nimbleFile] == failedLoad

    # the mtime moves explicitly so the change is seen on coarse filesystems
    let brokenTime = getLastModificationTime(nimbleFile.string)
    writeFile(
      nimbleFile.string,
      "version = \"0.1.0\"\nauthor = \"nimlangserver tests\"\n" &
        "description = \"Fixture: a package whose nimble file gets fixed\"\n" &
        "license = \"MIT\"\nsrcDir = \"src\"\n",
    )
    setLastModificationTime(nimbleFile.string, fromUnix(brokenTime.toUnix + 2))

    check (waitFor ls.getProjectFile(mainFile)) == mainFile
    check not ls.nimblePackages[nimbleFile].dumpFailed
    check ls.nimblePackages[nimbleFile].projectFile == mainFile

  test "a file outside the source dir belongs to the package project":
    let package = projectsDir / "mcpproject"
    check (waitFor ls.getProjectFile(package / "tests" / "test1.nim")) ==
      package / "src" / "mcpproject.nim"

  test "a file of a known package keeps resolving to it":
    let dep = projectsDir / "vendored" / "vendor" / "dep" / "dep.nim"
    check projectsDir / "vendored" / "vendored.nimble" in ls.nimblePackageLoads
    check (waitFor ls.getProjectFile(dep)) == projectsDir / "vendored" / "vendored.nim"

  test "nimsuggest runs in the folder of the file's package":
    let dep = projectsDir / "vendored" / "vendor" / "dep" / "dep.nim"
    check (waitFor ls.getWorkingDir(dep)) == projectsDir / "vendored"

  test "a file of a package without a project file runs in the package folder":
    let hw = projectsDir / "hw" / "hw.nim"
    check (waitFor ls.getWorkingDir(hw)) == projectsDir / "hw"

  test "nim comes from the Nim of the file's package":
    let dep = projectsDir / "vendored" / "vendor" / "dep" / "dep.nim"
    let package = ls.nimblePackages[projectsDir / "vendored" / "vendored.nimble"]
    let nimPath = waitFor ls.getNimPath(NlsConfig(), dep)
    if package.nimDir.isSome and package.nimDir.get.dirExists:
      check nimPath == some(package.nimDir.get / "nim".addFileExt(ExeExt))
    else:
      check nimPath == some(findExe "nim")

  test "no nimble dump is started once stopped":
    let nimbleFile = projectsDir / "multimodules" / "multimodules.nimble"
    check nimbleFile notin ls.nimblePackageLoads
    waitFor ls.shutdownNimsuggest()
    discard waitFor ls.getProjectFile(projectsDir / "multimodules" / "rootmodule.nim")
    check nimbleFile notin ls.nimblePackageLoads

suite "A project subfolder as the workspace":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )
  let projectsDir = absolutePath("tests" / "projects").Path
  let mono = projectsDir / "mono"
  let localDeps = projectsDir / "localdeps"
  discard waitFor client.initialize(
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": pathToUri(mono / "app"),
      "capabilities": {"workspace": {"configuration": true}},
    }
  )
  ls.setWorkspaceConfiguration(% @[NlsConfig()])

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "subfolder workspace resolves to parent dir nimble project":
    check (waitFor ls.getProjectFile(mono / "app" / "app.nim")) == mono / "mono.nim"
    check (waitFor ls.getWorkingDir(mono / "app" / "app.nim")) == mono

  test "a file outside the workspace resolves to its own package":
    # when the file is inside a nimble project (.nimble + nimble.paths),
    # then it resolves to it instead of the workspace project (ie: go-to-def file)
    check (waitFor ls.getProjectFile(localDeps / "vendor" / "v" / "v.nim")) ==
      localDeps / "localdeps.nim"
    check (waitFor ls.getWorkingDir(localDeps / "vendor" / "v" / "v.nim")) == localDeps

  test "a file outside the workspace and of any package is its own project":
    # ie: a go-to-def file; outside the langserver package, so it has no package
    let looseDir = getTempDir().Path / "nimlangserver-no-package"
    let loose = looseDir / "loose.nim"
    createDir(looseDir.string)
    writeFile(loose.string, "echo 1\n")
    check (waitFor ls.getProjectFile(loose)) == loose
    check (waitFor ls.getWorkingDir(loose)) == looseDir

  test "a project file path is not url decoded":
    # outside the langserver package, so the path comes from the auto guess
    let dir = getTempDir().Path / "nimlangserver-c++%20dir"
    let file = dir / "main.nim"
    createDir(dir.string)
    writeFile(file.string, "echo 1\n")
    check (waitFor ls.getProjectFile(file)) == file

suite "A sub package as the workspace":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )
  let projectsDir = absolutePath("tests" / "projects").Path
  let depDir = projectsDir / "vendored" / "vendor" / "dep"
  discard waitFor client.initialize(
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": pathToUri(depDir),
      "capabilities": {"workspace": {"configuration": true}},
    }
  )
  ls.setWorkspaceConfiguration(% @[NlsConfig()])

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "a sub package opened as the workspace is its own package":
    check (waitFor ls.getProjectFile(depDir / "dep.nim")) == depDir / "dep.nim"
    check depDir / "dep.nimble" in ls.nimblePackageLoads
    check projectsDir / "vendored" / "vendored.nimble" notin ls.nimblePackageLoads

suite "Projects with local dependencies":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )
  let projectsDir = absolutePath("tests" / "projects").Path
  let localDeps = projectsDir / "localdeps"
  let dep =
    localDeps / "nimbledeps" / "pkgs2" /
    "dep-0.1.0-0000000000000000000000000000000000000000"
  discard waitFor client.initialize(
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": pathToUri(localDeps),
      "capabilities": {"workspace": {"configuration": true}},
    }
  )
  ls.setWorkspaceConfiguration(% @[NlsConfig()])

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "a nested package that is set up is a project of its own":
    check (waitFor ls.getProjectFile(localDeps / "sub" / "sub.nim")) ==
      localDeps / "sub" / "sub.nim"
    check (waitFor ls.getWorkingDir(localDeps / "sub" / "sub.nim")) == localDeps / "sub"

  test "a dependency in nimbledeps belongs to the project that installed it":
    check (waitFor ls.getProjectFile(dep / "dep.nim")) == localDeps / "localdeps.nim"
    check (waitFor ls.getWorkingDir(dep / "dep.nim")) == localDeps

  test "a nested package that is not set up belongs to the project around it":
    check (waitFor ls.getProjectFile(localDeps / "vendor" / "v" / "v.nim")) ==
      localDeps / "localdeps.nim"
    check (waitFor ls.getWorkingDir(localDeps / "vendor" / "v" / "v.nim")) == localDeps

suite "Nimble package changes":
  let
    # outside the langserver package, so only the files written here make a package
    root = getTempDir().Path / "nimlangserver-package-changes"
    package = root / "changing"
    nimbleFile = package / "changing.nimble"
    nimblePaths = package / "nimble.paths"
    packageProject = package / "changing.nim"
    srcProject = package / "src" / "changing.nim"
    libFile = package / "lib.nim"
    otherFile = root / "other" / "other.nim"
    nimbleText =
      "version = \"0.1.0\"\nauthor = \"nimlangserver tests\"\n" &
      "description = \"Fixture: a package that changes\"\nlicense = \"MIT\"\n"

  proc open(client: LspSocketClient, path: Path) =
    client.notify(
      "textDocument/didOpen",
      %*{
        "textDocument": {
          "uri": pathToUri(path),
          "languageId": "nim",
          "version": 0,
          "text": readFile(path.string),
        }
      },
    )

  proc hover(client: LspSocketClient, path: Path) =
    discard client.call(
      "textDocument/hover",
      %*{
        "textDocument": {"uri": pathToUri(path)},
        "position": {"line": 0, "character": 5},
      },
    ).waitFor

  proc projectOf(ls: LanguageServer, path: Path): Path =
    waitFor ls.openFiles[path].projectFileWait()

  proc started(ls: LanguageServer, projectFile: Path): bool =
    waitUntil(projectFile in ls.projectFiles, chronos.seconds(60))

  # the mtime moves explicitly so the change is seen on coarse filesystems
  proc rewrite(path: Path, text: string) =
    let time = getLastModificationTime(path.string)
    writeFile(path.string, text)
    setLastModificationTime(path.string, fromUnix(time.toUnix + 2))

  setup:
    removeDir(root.string)
    createDir((package / "src").string)
    createDir(otherFile.parentDir.string)
    writeFile(packageProject.string, "echo 1\n")
    writeFile(srcProject.string, "echo 1\n")
    writeFile(libFile.string, "proc a*() = discard\n")
    writeFile(otherFile.string, "proc b*() = discard\n")
    writeFile(nimbleFile.string, nimbleText)

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
        "rootUri": pathToUri(root),
        "capabilities": {"workspace": {"configuration": true}},
      }
    )
    ls.setWorkspaceConfiguration(% @[NlsConfig(maxNimsuggestProcesses: some 0)])

  teardown:
    waitFor ls.shutdownNimsuggest()
    waitFor ls.onExit()
    removeDir(root.string)

  test "a request with no nimble.paths change keeps the nimsuggest":
    client.open(libFile)
    check ls.started(packageProject)
    check ls.projectOf(libFile) == packageProject
    let project = ls.projectFiles[packageProject]

    client.hover(libFile)
    check ls.projectFiles[packageProject] == project

  test "a new nimble.paths restarts the nimsuggest of the package":
    client.open(libFile)
    check ls.started(packageProject)
    let project = ls.projectFiles[packageProject]

    writeFile(nimblePaths.string, "--noNimblePath\n")
    client.hover(libFile)
    check ls.projectFiles[packageProject] != project
    check ls.openFiles[libFile].nimsuggestProject == packageProject

  test "an edited nimble.paths restarts the nimsuggest of the package":
    writeFile(nimblePaths.string, "--noNimblePath\n")
    client.open(libFile)
    check ls.started(packageProject)
    let project = ls.projectFiles[packageProject]

    rewrite(nimblePaths, "--noNimblePath\n--path:\"x\"\n")
    client.hover(libFile)
    check ls.projectFiles[packageProject] != project

  test "a nimble.paths rewritten with the same contents keeps the nimsuggest":
    # nimble test and nimble tasks rewrite it on every run
    writeFile(nimblePaths.string, "--noNimblePath\n")
    client.open(libFile)
    check ls.started(packageProject)
    let project = ls.projectFiles[packageProject]

    rewrite(nimblePaths, "--noNimblePath\n")
    client.hover(libFile)
    check ls.projectFiles[packageProject] == project

    # a later change of the contents still restarts it
    rewrite(nimblePaths, "--noNimblePath\n--path:\"x\"\n")
    client.hover(libFile)
    check ls.projectFiles[packageProject] != project

  test "a deleted nimble.paths restarts the nimsuggest of the package":
    writeFile(nimblePaths.string, "--noNimblePath\n")
    client.open(libFile)
    check ls.started(packageProject)
    let project = ls.projectFiles[packageProject]

    removeFile(nimblePaths.string)
    client.hover(libFile)
    check ls.projectFiles[packageProject] != project

  test "concurrent requests share the restart of a changed nimble.paths":
    client.open(libFile)
    check ls.started(packageProject)
    let project = ls.projectFiles[packageProject]

    writeFile(nimblePaths.string, "--noNimblePath\n")
    let
      first = ls.tryGetNimsuggest(libFile)
      second = ls.tryGetNimsuggest(libFile)
    # the old nimsuggest stays until it has exited, so nothing starts meanwhile
    check ls.projectFiles[packageProject] == project
    check packageProject notin ls.nimsuggestCreations

    check (waitFor first).get == (waitFor second).get
    check ls.projectFiles[packageProject] != project
    check project.process.running() == AsyncProcessResult[bool].ok(false)

  test "a nimble.paths change during startup restarts the nimsuggest once":
    # the project check that follows a startup is a request too
    ls.setWorkspaceConfiguration(% @[NlsConfig(autoCheckProject: some false)])
    defer:
      ls.setWorkspaceConfiguration(% @[NlsConfig()])
    writeFile(nimblePaths.string, "--noNimblePath\n")
    client.open(libFile)
    check ls.started(packageProject)
    let old = ls.projectFiles[packageProject]
    ls.projectFiles.del(packageProject)
    waitFor old.stopWait()

    # with nothing to stop first, the stamp is taken before the startup waits
    let starting = ls.createOrRestartNimsuggest(packageProject, packageProject)
    check packageProject in ls.nimsuggestCreations
    rewrite(nimblePaths, "--noNimblePath\n--path:\"z\"\n")

    # a request during the startup waits for it instead of stopping it
    let first = waitFor ls.tryGetNimsuggest(libFile)
    check starting.finished
    let startedProject = ls.projectFiles[packageProject]
    check first.get == startedProject.ns

    # the next one restarts it, since it may have missed the change
    check (waitFor ls.tryGetNimsuggest(libFile)).isSome
    let restarted = ls.projectFiles[packageProject]
    check restarted != startedProject
    check not restarted.failed

    check (waitFor ls.tryGetNimsuggest(libFile)).isSome
    check ls.projectFiles[packageProject] == restarted

  test "a nimble.paths change retries a failed nimsuggest":
    client.open(libFile)
    check ls.started(packageProject)
    let project = ls.projectFiles[packageProject]
    discard project.process.kill()
    check waitUntil(project.failed)
    check (waitFor ls.tryGetNimsuggest(libFile)).isNone
    check ls.projectFiles[packageProject] == project

    # nimble setup may install what it was missing
    writeFile(nimblePaths.string, "--noNimblePath\n")
    check (waitFor ls.tryGetNimsuggest(libFile)).isSome
    check ls.projectFiles[packageProject] != project
    check not ls.projectFiles[packageProject].failed

  test "an edited nimble file alone keeps the nimsuggest":
    client.open(libFile)
    check ls.started(packageProject)
    let project = ls.projectFiles[packageProject]

    rewrite(nimbleFile, nimbleText & "srcDir = \"src\"\n")
    client.hover(libFile)
    check ls.projectFiles[packageProject] == project
    check ls.projectOf(libFile) == packageProject

  test "a changed nimble.paths also picks up the edits of the nimble file":
    client.open(libFile)
    check ls.started(packageProject)

    rewrite(nimbleFile, nimbleText & "srcDir = \"src\"\n")
    writeFile(nimblePaths.string, "--noNimblePath\n")
    client.hover(libFile)
    check packageProject notin ls.projectFiles
    check ls.projectOf(libFile) == srcProject
    check ls.openFiles[libFile].nimsuggestProject == srcProject
    check srcProject in ls.projectFiles

  test "a project outside the package is not restarted":
    client.open(libFile)
    client.open(otherFile)
    check ls.started(packageProject)
    check ls.started(otherFile)
    let project = ls.projectFiles[otherFile]

    writeFile(nimblePaths.string, "--noNimblePath\n")
    client.hover(otherFile)
    check ls.projectFiles[otherFile] == project
    check project.nimblePaths.len == 0
