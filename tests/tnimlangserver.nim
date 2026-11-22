import
  std/[options, json, os, sequtils, strutils, sugar, strformat],
  json_rpc/[rpcclient],
  unittest2,
  ../[nimlangserver, ls, utils],
  ../protocol/[types],
  ./lspsocketclient

suite "Nimlangserver":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )
  waitFor client.connect("localhost", cmdParams.port)

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "initialize from the client should call initialized on the server":
    let initParams =
      %*{
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/hw/"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    let initializeResult = waitFor client.initialize(initParams)
    ls.setWorkspaceConfiguration(% @[NlsConfig()])

    check "textDocumentSync" in initializeResult["capabilities"]

let helloWorldUri = fixtureUri("projects/hw/hw.nim")

suite "Suggest API selection":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )

  waitFor client.connect("localhost", cmdParams.port)
  let initParams =
    %*{
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities":
        {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
    }
  discard waitFor client.initialize(initParams)
  ls.setWorkspaceConfiguration(% @[NlsConfig()])
  client.notify("initialized", newJObject())

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "Suggest api":
    #The client adds the notifications into the call table and we wait until they arrived.   
    let helloWorldFile = "projects/hw/hw.nim"
    client.openFile(helloWorldFile)

    let hwAbsFile = helloWorldFile.fixtureUri.uriToPath
    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {hwAbsFile}"
    )

    client.notify(
      "textDocument/didOpen", %createDidOpenParams("projects/hw/useRoot.nim")
    )
    let
      hoverParams = positionParams("projects/hw/hw.nim".fixtureUri, 2, 0)
      hover = client.call("textDocument/hover", %hoverParams).waitFor
    check hover.kind == JNull

suite "LSP features":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )

  waitFor client.connect("localhost", cmdParams.port)

  let initParams =
    %*{
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities":
        {"window": {"workDoneProgress": false}, "workspace": {"configuration": true}},
    }

  discard waitFor client.initialize(initParams)
  ls.setWorkspaceConfiguration(% @[NlsConfig()])

  client.notify("initialized", newJObject())
  let didOpenParams = createDidOpenParams("projects/hw/hw.nim")

  client.notify("textDocument/didOpen", %didOpenParams)

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "Sending hover.":
    let
      hoverParams = positionParams(helloWorldUri, 1, 6)
      hover = client.call("textDocument/hover", %hoverParams).waitFor
      expected = %*{
        "contents": {
          "kind": "markdown",
          "value":
            "```nim\nhw.a안녕: proc (){.noSideEffect, gcsafe, raises: <inferred> [].}\n```",
        },
        "range":
          {"start": {"line": 1, "character": 6}, "end": {"line": 1, "character": 9}},
      }
    check hover == expected

  test "Sending hover(no content)":
    block:
      let
        hoverParams = positionParams(helloWorldUri, 1, 5)
        hover = client.call("textDocument/hover", %hoverParams).waitFor
      check hover.kind == JNull
    block:
      let
        hoverParams = positionParams(helloWorldUri, 2, 0)
        hover = client.call("textDocument/hover", %hoverParams).waitFor
      check hover.kind == JNull

  test "Definitions.":
    let
      positionParams = positionParams(helloWorldUri, 1, 6)
      locations = to(
        waitFor client.call("textDocument/definition", %positionParams), seq[Location]
      )
      expected = @[Location(uri: helloWorldUri, `range`: range(0, 5, 0, 8))]
    check %locations == %expected

  test "References.":
    let referenceParams =
      %*{
        "context": {"includeDeclaration": true},
        "position": {"line": 1, "character": 6},
        "textDocument": {"uri": helloWorldUri},
      }
    let locations = to(
      waitFor client.call("textDocument/references", %referenceParams), seq[Location]
    )
    let expected = @[
      Location(uri: helloWorldUri, `range`: range(0, 5, 0, 8)),
      Location(uri: helloWorldUri, `range`: range(1, 6, 1, 9)),
    ]
    check %locations == %expected

  test "References(exclude def)":
    let referenceParams =
      %*{
        "context": {"includeDeclaration": false},
        "position": {"line": 1, "character": 7},
        "textDocument": {"uri": helloWorldUri},
      }
    let locations = to(
      waitFor client.call("textDocument/references", %referenceParams), seq[Location]
    )
    let expected = @[Location(uri: helloWorldUri, `range`: range(1, 6, 1, 9))]
    check %locations == %expected

  test "Prepare rename":
    let renameParams = PrepareRenameParams(
      textDocument: TextDocumentIdentifier(uri: helloWorldUri),
      position: Position(line: uinteger(2), character: uinteger(6)),
    )
    let resp = client.call("textDocument/prepareRename", %renameParams).waitFor()
    check resp ==
      %*{"start": {"line": 2, "character": 4}, "end": {"line": 2, "character": 7}}

  test "Prepare rename doesn't allow non-project symbols":
    let renameParams = PrepareRenameParams(
      textDocument: TextDocumentIdentifier(uri: helloWorldUri),
      position: Position(line: uinteger(8), character: uinteger(10)),
    )
    let resp = client.call("textDocument/prepareRename", %renameParams).waitFor()
    check resp.kind == JNull

  test "Rename":
    let renameParams = RenameParams(
      textDocument: TextDocumentIdentifier(uri: helloWorldUri),
      newName: "hello",
      position: Position(line: uinteger(2), character: uinteger(6)),
    )
    let changes =
      client.call("textDocument/rename", %renameParams).waitFor()["changes"]
    check changes.len == 1
    check changes[helloWorldUri.string].len == 3
    check changes[helloWorldUri.string].getElems.mapIt(it["newText"].getStr()) ==
      @["hello", "hello", "hello"]

  test "didChange then sending hover.":
    let didChangeParams =
      %*{
        "textDocument": {"uri": helloWorldUri, "version": 1},
        "contentChanges": [{"text": "\nproc a() = discard\na()\n"}],
      }

    client.notify("textDocument/didChange", %didChangeParams)
    let
      hoverParams = positionParams(fixtureUri("projects/hw/hw.nim"), 2, 0)
      hover = client.call("textDocument/hover", %hoverParams).waitFor
    check contains($hover, "hw.a: proc ()")

  test "Completion":
    let completionParams =
      %*{
        "position": {"line": 3, "character": 2},
        "textDocument": {"uri": fixtureUri("projects/hw/hw.nim")},
      }

    let actualEchoCompletionItem = waitFor(
      client.call("textDocument/completion", %completionParams)
    ).getElems
      .filter(item => item["label"].getStr == "echo")[0]

    check actualEchoCompletionItem["kind"].getInt == 3
    check actualEchoCompletionItem["detail"].getStr.contains("proc")
    check actualEchoCompletionItem["documentation"].kind == JString

  test "Shutdown":
    let
      nullValue = newJNull()
      nullResponse = waitFor client.call("shutdown", nullValue)

    check nullResponse == nullValue
    check ls.isShutdown

suite "Null configuration:":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "extension/statusUpdate",
    "textDocument/publishDiagnostics", "$/progress",
  )

  waitFor client.connect("localhost", cmdParams.port)

  let initParams =
    %*{
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities": {
        "workspace": {"configuration": true},
        "textDocument": {"rename": {"prepareSupport": true}},
      },
    }

  discard waitFor client.initialize(initParams)
  ls.setWorkspaceConfiguration(% @[NlsConfig()])
  client.notify("initialized", newJObject())

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "Null configuration":
    client.notify("textDocument/didOpen", %createDidOpenParams("projects/hw/hw.nim"))
    let hoverParams = positionParams("projects/hw/hw.nim".fixtureUri, 2, 0)
    let hover = client.call("textDocument/hover", %hoverParams).waitFor
    check hover.kind == JNull
