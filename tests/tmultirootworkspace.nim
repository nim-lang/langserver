import
  std/[options, json, os, tables, strutils],
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
      # The tests set the configuration themselves, so the server must not pull it.
      "capabilities": {},
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
    waitFor ls.didOpenFixture("projects/multimodules/othermodule.nim")
    check (waitFor ls.openFiles[otherModule].projectFileWait()) == rootModule

    # Without its workspace the mapping no longer applies to the file.
    client.notify(
      "workspace/didChangeWorkspaceFolders", folderChange(@[], @[modulesDir])
    )
    check waitUntil(ls.workspaceFolders == @[hwDir.Path])
    check (waitFor ls.openFiles[otherModule].projectFileWait()) != rootModule

    client.notify(
      "workspace/didChangeWorkspaceFolders", folderChange(@[modulesDir], @[])
    )
    check waitUntil(ls.workspaceFolders == @[hwDir.Path, modulesDir.Path])
    check (waitFor ls.openFiles[otherModule].projectFileWait()) == rootModule

  test "a workspace change with an invalid uri is not applied":
    let folders = ls.workspaceFolders
    check hwDir in folders
    var change = folderChange(@[], @[hwDir])
    change["event"]["added"] = %*[{"uri": "untitled:Foo", "name": "foo"}]
    client.notify("workspace/didChangeWorkspaceFolders", change)
    discard waitFor client.call("extension/status", newJObject())
    check ls.workspaceFolders == folders

  test "a workspace change stops the nimsuggests when they are capped":
    let hwFile = hwDir / "hw.nim"
    ls.setWorkspaceConfiguration(% @[NlsConfig(maxNimsuggestProcesses: some 2)])
    waitFor ls.didOpenFixture("projects/hw/hw.nim")
    check (waitFor ls.tryGetNimsuggest(hwFile)).isSome
    client.notify(
      "workspace/didChangeWorkspaceFolders",
      folderChange(@[projectsDir / "vendored"], @[]),
    )
    check waitUntil(ls.projectFiles.len == 0)

  test "a workspace change keeps the nimsuggests when they are not capped":
    let hwFile = hwDir / "hw.nim"
    ls.setWorkspaceConfiguration(% @[NlsConfig(maxNimsuggestProcesses: some 0)])
    check (waitFor ls.tryGetNimsuggest(hwFile)).isSome
    let project = ls.projectFiles.getOrDefault(ls.openFiles[hwFile].nimsuggestProject)
    check project != nil
    client.notify(
      "workspace/didChangeWorkspaceFolders",
      folderChange(@[], @[projectsDir / "vendored"]),
    )
    check waitUntil(projectsDir / "vendored" notin ls.workspaceFolders)
    discard waitFor client.call("extension/status", newJObject())
    check ls.projectFiles.getOrDefault(project.file) == project

suite "Configuration per workspace":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "extension/statusUpdate",
    "textDocument/publishDiagnostics", "$/progress",
  )

  # Only the multimodules folder maps othermodule to rootmodule.
  proc answerConfiguration(params: JsonNode): Future[JsonNode] {.async.} =
    {.cast(gcsafe).}:
      result = newJArray()
      for item in params["items"]:
        if item{"scopeUri"}.getStr == $pathToUri(modulesDir):
          result.add %*{
            "projectMapping":
              [{"projectFile": "rootmodule.nim", "fileRegex": "othermodule"}]
          }
        else:
          result.add newJObject()

  client.registerRequest("workspace/configuration", answerConfiguration)

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  discard waitFor client.initialize(
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "workspaceFolders": [
        {"uri": pathToUri(hwDir), "name": "hw"},
        {"uri": pathToUri(modulesDir), "name": "multimodules"},
      ],
      "capabilities": {"workspace": {"configuration": true}},
    }
  )
  client.notify("initialized", newJObject())
  check waitUntil(ls.workspaceConfigurationReady.finished)

  test "a folder's configuration applies to the files in it":
    check ls.workspaceConfiguration.projectMapping.get(@[]).len == 0
    check (waitFor ls.getProjectFile(otherModule)) == rootModule

  test "a folder added later is asked for its configuration":
    client.notify(
      "workspace/didChangeWorkspaceFolders", folderChange(@[], @[modulesDir])
    )
    check waitUntil(modulesDir notin ls.folderConfigurations)
    client.notify(
      "workspace/didChangeWorkspaceFolders", folderChange(@[modulesDir], @[])
    )
    check waitUntil(modulesDir in ls.folderConfigurations)
    check (waitFor ls.getProjectFile(otherModule)) == rootModule

suite "Invalid workspace":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newClient(cmdParams.port)

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "initialize with a non file root is answered with an error":
    var raised = false
    try:
      discard waitFor client.initialize(
        LspInitializeParams %* {
          "processId": %getCurrentProcessId(),
          "rootUri": "untitled:Foo",
          "capabilities": {},
        }
      )
    except CatchableError as ex:
      raised = true
      check "-32602" in ex.msg
    check raised
    check not ls.initialized

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
