import
  std/[options, json, os, sequtils, tables],
  json_rpc/[rpcclient],
  unittest2,
  ../[nimlangserver, ls, utils],
  ../protocol/[types],
  ./[lspsocketclient, testhelpers]

const
  RootFile = "projects/multimodules/rootmodule.nim"
  OtherFile = "projects/multimodules/othermodule.nim"

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
  # Only the checks a test runs report progress.
  ls.setWorkspaceConfiguration(
    % @[NlsConfig(autoCheckFile: some false, autoCheckProject: some false)]
  )
  client.notify("textDocument/didOpen", %createDidOpenParams(RootFile))
  discard waitFor client
    .call("textDocument/completion", %positionParams(RootFile.fixtureUri, 4, 7))
    .wait(60.seconds)
  (ls, client)

proc createdTokens(client: LspSocketClient): seq[string] =
  client.calls["window/workDoneProgress/create"].mapIt(it["token"].getStr)

proc progressKinds(client: LspSocketClient, token: string): seq[string] =
  for params in client.calls["$/progress"]:
    if params["token"].getStr == token:
      result.add params["value"]["kind"].getStr

proc newTokens(client: LspSocketClient, since: int): seq[string] =
  client.createdTokens()[since ..^ 1]

proc isEnded(client: LspSocketClient, token: string): bool =
  client.progressKinds(token) == @["begin", "end"]

suite "Progress of file checks":
  let (ls, client) = startServer()
  let uri = RootFile.fixtureUri

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "overlapping checks of a file report their own progress":
    let created = client.createdTokens().len
    let first = ls.checkFile(ls.openFiles[uri])
    let second = ls.checkFile(ls.openFiles[uri])
    waitFor allFutures(first, second)

    check waitUntil(client.newTokens(created).len == 2)
    let tokens = client.newTokens(created)
    check tokens.deduplicate.len == 2
    for token in tokens:
      check waitUntil(client.isEnded(token))

  test "the progress of a check without a nimsuggest is ended":
    # A closed file whose project is gone: nothing checks it.
    let info = NlsFileInfo(
      textDocument: TextDocumentItem(uri: OtherFile.fixtureUri),
      nimsuggestProject: OtherFile.fixtureUri.uriToPath,
    )
    check OtherFile.fixtureUri notin ls.openFiles
    check info.nimsuggestProject notin ls.projectFiles

    let created = client.createdTokens().len
    waitFor ls.checkFile(info)
    check waitUntil(client.newTokens(created).len == 1)
    check waitUntil(client.isEnded(client.newTokens(created)[0]))

suite "Progress of project checks":
  let (ls, client) = startServer()
  let uri = RootFile.fixtureUri

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "every project check reports its own progress":
    ls.setWorkspaceConfiguration(
      % @[NlsConfig(autoCheckFile: some false, autoCheckProject: some true)]
    )
    let created = client.createdTokens().len
    waitFor ls.checkProject(uri)
    waitFor ls.checkProject(uri)

    check waitUntil(client.newTokens(created).len == 2)
    let tokens = client.newTokens(created)
    check tokens.deduplicate.len == 2
    for token in tokens:
      check waitUntil(client.isEnded(token))

  test "the progress of a recompile is ended":
    ls.setWorkspaceConfiguration(
      % @[NlsConfig(autoCheckFile: some false, autoCheckProject: some false)]
    )
    let created = client.createdTokens().len
    discard waitFor client
      .call(
        "workspace/executeCommand",
        %*{"command": RECOMPILE_COMMAND, "arguments": [uri.uriToPath]},
      )
      .wait(60.seconds)

    check waitUntil(client.newTokens(created).len == 1, 60.seconds)
    check waitUntil(client.isEnded(client.newTokens(created)[0]), 60.seconds)
