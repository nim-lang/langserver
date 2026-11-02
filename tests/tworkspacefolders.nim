import
  std/[options, json, os, tables],
  chronos,
  unittest2,
  ../[nimlangserver, ls, utils],
  ../protocol/types,
  ./[lspsocketclient, testhelpers]

proc newClient(port: Port): LspSocketClient =
  result = newLspSocketClient()
  waitFor result.connect("localhost", port)
  result.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )

let
  projectsDir = absolutePath "tests" / "projects"
  hwDir = projectsDir / "hw"
  modulesDir = projectsDir / "multimodules"
  otherModule = modulesDir / "othermodule.nim"
  rootModule = modulesDir / "rootmodule.nim"

proc folderChange(added, removed: seq[string]): JsonNode =
  proc folders(dirs: seq[string]): JsonNode =
    result = newJArray()
    for dir in dirs:
      result.add %*{"uri": pathToUri(dir), "name": dir.extractFilename}

  %*{"event": {"added": folders(added), "removed": folders(removed)}}

suite "Workspace folders":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newClient(cmdParams.port)

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  # The deprecated rootUri points somewhere else, so only the folders can
  # explain what the server ends up with.
  let initResult = waitFor client.initialize(
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/vendored"),
      "workspaceFolders": [
        {"uri": pathToUri(hwDir), "name": "hw"},
        {"uri": pathToUri(modulesDir), "name": "multimodules"},
      ],
      "capabilities": {"workspace": {"configuration": true}},
    }
  )
  # The regex matches the path relative to the file's folder.
  ls.setWorkspaceConfiguration(
    % @[
      NlsConfig(
        projectMapping: some @[
          NlsNimsuggestConfig(projectFile: "rootmodule.nim", fileRegex: "othermodule")
        ]
      )
    ]
  )

  test "the workspace folders take precedence over the root":
    check ls.workspaceFolders == @[hwDir, modulesDir]
    let capability = initResult.capabilities.workspace.get.workspaceFolders.get
    check capability.supported == some(true)
    check capability.changeNotifications == some(%true)

  test "a file belongs to the folder that contains it":
    check ls.workspaceFolderOf(hwDir / "hw.nim") == hwDir
    check ls.workspaceFolderOf(otherModule) == modulesDir
    check ls.workspaceFolderOf(projectsDir / "vendored" / "vendored.nim") == ""

  test "a project mapping is relative to the folder of the file":
    check (waitFor ls.getProjectFile(otherModule)) == rootModule

  test "a file outside of any package runs in its folder":
    check (waitFor ls.getWorkingDir(hwDir / "hw.nim")) == hwDir

  test "the open files follow the folders the client adds and removes":
    waitFor ls.didOpenFile(
      createDidOpenParams("projects/multimodules/othermodule.nim").textDocument
    )
    let uri = pathToUri(otherModule)
    check (waitFor ls.openFiles[uri].waitProjectFile()) == rootModule

    # Without its folder the mapping no longer applies to the file.
    client.notify(
      "workspace/didChangeWorkspaceFolders", folderChange(@[], @[modulesDir])
    )
    check waitUntil(ls.workspaceFolders == @[hwDir])
    check (waitFor ls.openFiles[uri].waitProjectFile()) != rootModule

    client.notify(
      "workspace/didChangeWorkspaceFolders", folderChange(@[modulesDir], @[])
    )
    check waitUntil(ls.workspaceFolders == @[hwDir, modulesDir])
    check (waitFor ls.openFiles[uri].waitProjectFile()) == rootModule

suite "No workspace folders":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newClient(cmdParams.port)

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  discard waitFor client.initialize(
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": nil,
      "workspaceFolders": nil,
      "capabilities": {"workspace": {"configuration": true}},
    }
  )
  ls.setWorkspaceConfiguration(% @[NlsConfig()])

  test "a file outside of any package runs in its own directory":
    check ls.workspaceFolders.len == 0
    check ls.workspaceFolderOf(hwDir / "hw.nim") == ""
    # The fixtures are inside the langserver package, so this one is not.
    let
      dir = getTempDir() / "nimlangserver-no-folders"
      path = dir / "main.nim"
    createDir(dir)
    writeFile(path, "echo 1\n")
    check (waitFor ls.getWorkingDir(path)) == dir

suite "Packages of workspace folders":
  let
    tmp = getTempDir() / "nimlangserver-workspace-packages"
    mono = tmp / "mono"
    outer = tmp / "outer"
    depDir = projectsDir / "vendored" / "vendor" / "dep"

  proc writePackage(dir, name: string) =
    createDir(dir)
    writeFile(
      dir / name & ".nimble",
      "version = \"0.1.0\"\nauthor = \"test\"\ndescription = \"test\"\nlicense = \"MIT\"\n",
    )
    writeFile(dir / name & ".nim", "echo 1\n")

  # These live outside the langserver package, which would otherwise be the
  # outermost package of all of them.
  writePackage(mono, "mono")
  createDir(mono / "app")
  writeFile(mono / "app" / "app.nim", "echo 1\n")
  writePackage(outer, "outer")
  writePackage(outer / "vendor" / "dep", "dep")
  createDir(tmp / "loose")
  writeFile(tmp / "loose" / "loose.nim", "echo 1\n")

  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newClient(cmdParams.port)

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  discard waitFor client.initialize(
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "workspaceFolders": [
        {"uri": pathToUri(mono / "app"), "name": "app"},
        {"uri": pathToUri(depDir), "name": "dep"},
        {"uri": pathToUri(tmp / "loose"), "name": "loose"},
      ],
      "capabilities": {"workspace": {"configuration": true}},
    }
  )
  ls.setWorkspaceConfiguration(% @[NlsConfig()])

  test "a folder without a package belongs to the package around it":
    check (waitFor ls.getProjectFile(mono / "app" / "app.nim")) == mono / "mono.nim"
    check (waitFor ls.getWorkingDir(mono / "app" / "app.nim")) == mono

  test "a folder that is a package is its own package":
    check (waitFor ls.getProjectFile(depDir / "dep.nim")) == depDir / "dep.nim"
    check depDir / "dep.nimble" in ls.nimblePackageLoads
    check projectsDir / "vendored" / "vendored.nimble" notin ls.nimblePackageLoads

  test "a vendored file outside the folders belongs to the outermost package":
    let dep = outer / "vendor" / "dep" / "dep.nim"
    check (waitFor ls.getProjectFile(dep)) == outer / "outer.nim"

  test "a file with no package anywhere runs in its folder":
    check (waitFor ls.getWorkingDir(tmp / "loose" / "loose.nim")) == tmp / "loose"
