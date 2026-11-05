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
  projectsDir = absolutePath("tests" / "projects").Path
  hwDir = projectsDir / "hw"
  modulesDir = projectsDir / "multimodules"
  otherModule = modulesDir / "othermodule.nim"
  rootModule = modulesDir / "rootmodule.nim"

proc folderChange(added, removed: seq[Path]): JsonNode =
  proc folders(dirs: seq[Path]): JsonNode =
    result = newJArray()
    for dir in dirs:
      result.add %*{"uri": pathToUri(dir), "name": $dir.extractFilename}

  %*{"event": {"added": folders(added), "removed": folders(removed)}}

suite "Several workspaces":
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
  # The regex matches the path relative to the file's workspace.
  ls.setWorkspaceConfiguration(
    % @[
      NlsConfig(
        projectMapping: some @[
          NlsNimsuggestConfig(projectFile: "rootmodule.nim", fileRegex: "othermodule")
        ]
      )
    ]
  )

  test "the workspace folders take precedence over the root uri":
    check ls.workspaceFolders == @[hwDir.Path, modulesDir.Path]
    let capability = initResult.capabilities.workspace.get.workspaceFolders.get
    check capability.supported == some(true)
    check capability.changeNotifications == some(%true)

  test "a file belongs to the workspace that contains it":
    check ls.workspaceFolderOf(hwDir / "hw.nim") == hwDir
    check ls.workspaceFolderOf(otherModule) == modulesDir
    check ls.workspaceFolderOf(projectsDir / "vendored" / "vendored.nim").len == 0

  test "a project mapping is relative to the workspace of the file":
    check (waitFor ls.getProjectFile(otherModule)) == rootModule

  test "open files resolve again when the client adds and removes workspaces":
    waitFor ls.didOpenFile(
      createDidOpenParams("projects/multimodules/othermodule.nim").textDocument
    )
    let uri = pathToUri(otherModule)
    check (waitFor ls.openFiles[uri].projectFileWait()) == rootModule

    # Without its workspace the mapping no longer applies to the file.
    client.notify(
      "workspace/didChangeWorkspaceFolders", folderChange(@[], @[modulesDir])
    )
    check waitUntil(ls.workspaceFolders == @[hwDir.Path])
    check (waitFor ls.openFiles[uri].projectFileWait()) != rootModule

    client.notify(
      "workspace/didChangeWorkspaceFolders", folderChange(@[modulesDir], @[])
    )
    check waitUntil(ls.workspaceFolders == @[hwDir.Path, modulesDir.Path])
    check (waitFor ls.openFiles[uri].projectFileWait()) == rootModule

suite "No workspace":
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

  test "a file outside the workspace and of any package runs in its own dir":
    check ls.workspaceFolders.len == 0
    check ls.workspaceFolderOf(hwDir / "hw.nim").len == 0
    # The fixtures are inside the langserver package, so this one is not.
    let
      dir = getTempDir().Path / "nimlangserver-no-folders"
      path = dir / "main.nim"
    createDir(dir.string)
    writeFile(path.string, "echo 1\n")
    check (waitFor ls.getWorkingDir(path)) == dir

suite "Workspaces without a nimble file":
  let
    mono = projectsDir / "mono"
    # Outside the langserver package, so it belongs to no package.
    loose = getTempDir().Path / "nimlangserver-workspace-packages" / "loose"
  createDir(loose.string)
  writeFile((loose / "loose.nim").string, "echo 1\n")

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
        {"uri": pathToUri(mono / "app2"), "name": "app2"},
        {"uri": pathToUri(loose), "name": "loose"},
      ],
      "capabilities": {"workspace": {"configuration": true}},
    }
  )
  ls.setWorkspaceConfiguration(% @[NlsConfig()])

  test "sibling subfolder workspaces resolve to the same parent dir nimble project":
    check (waitFor ls.getProjectFile(mono / "app2" / "app2.nim")) == mono / "mono.nim"
    check (waitFor ls.getProjectFile(mono / "app" / "app.nim")) == mono / "mono.nim"
    check (waitFor ls.getWorkingDir(mono / "app" / "app.nim")) == mono
    check (waitFor ls.getWorkingDir(mono / "app2" / "app2.nim")) == mono

  test "a workspace without any package runs in the workspace dir":
    check (waitFor ls.getWorkingDir(loose / "loose.nim")) == loose
