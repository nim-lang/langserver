import
  ../nimlangserver,
  ../protocol/types,
  ../utils,
  faststreams/async_backend,
  faststreams/asynctools_adapters,
  json_rpc/jsonmarshal,
  json_rpc/streamconnection,
  chronicles,
  os,
  sequtils,
  std/json,
  strformat,
  sugar,
  unittest

proc fixtureUri(path: string): string =
  result = pathToUri(getCurrentDir() / "tests" / path)

suite "Client/server initialization sequence":
  let pipeServer = createPipe();
  let pipeClient = createPipe();

  let
    server = StreamConnection.new(pipeServer)
    inputPipe = asyncPipeInput(pipeClient)
  discard registerHandlers(server, inputPipe);
  discard server.start(inputPipe);

  let client = StreamConnection.new(pipeClient);
  discard client.start(asyncPipeInput(pipeServer));

  test "Sending initialize.":
    let initParams = InitializeParams(
        processId: some(%getCurrentProcessId()),
        rootUri: "file:///tmp/",
        capabilities: ClientCapabilities())

    let initializeResult = waitFor client.call("initialize", %initParams)
    doAssert initializeResult != nil;

    client.notify("initialized", newJObject())

  pipeClient.close()
  pipeServer.close()

proc testHandler[T, Q](input: tuple[fut: FutureStream[T], res: Q], arg: T):
    Future[Q] {.async, gcsafe.} =
  debug "Received call: ", arg = %arg
  discard input.fut.write(arg)
  return input.res

proc testHandler[T](fut: FutureStream[T], arg: T): Future[void] {.async, gcsafe.} =
  debug "Received notification: ", arg = %arg
  discard fut.write(arg)

let helloWorldUri = fixtureUri("projects/hw/hw.nim")

proc createDidOpenParams(file: string): DidOpenTextDocumentParams =
  return DidOpenTextDocumentParams %* {
    "textDocument": {
      "uri": fixtureUri(file),
      "languageId": "nim",
      "version": 0,
      "text": readFile("tests" / file)
     }
  }

proc positionParams(uri: string, line, character: int): TextDocumentPositionParams =
  return TextDocumentPositionParams %* {
      "position": {
         "line": line,
         "character": character
      },
      "textDocument": {
         "uri": uri
       }
    }

suite "Suggest API selection":
  let pipeServer = createPipe();
  let pipeClient = createPipe();

  let
    server = StreamConnection.new(pipeServer)
    inputPipe = asyncPipeInput(pipeClient)
  discard registerHandlers(server, inputPipe);
  discard server.start(inputPipe);

  let client = StreamConnection.new(pipeClient);
  discard client.start(asyncPipeInput(pipeServer));

  let suggestInit = FutureStream[ProgressParams]()
  client.register("window/workDoneProgress/create",
                            partial(testHandler[ProgressParams, JsonNode],
                                    (fut: suggestInit, res: newJNull())))
  let workspaceConfiguration = %* [{
      "projectMapping": [{
        "projectFile": "missingRoot.nim",
        "fileRegex": "willCrash\\.nim"
      }, {
        "projectFile": "hw.nim",
        "fileRegex": "hw\\.nim"
      }, {
        "projectFile": "root.nim",
        "fileRegex": "useRoot\\.nim"
      }],
      "autoCheckFile": false,
      "autoCheckProject": false
  }]

  let configInit = FutureStream[ConfigurationParams]()
  client.register(
    "workspace/configuration",
    partial(testHandler[ConfigurationParams, JsonNode],
            (fut: configInit, res: workspaceConfiguration)))

  let diagnostics = FutureStream[PublishDiagnosticsParams]()
  client.registerNotification(
    "textDocument/publishDiagnostics",
    partial(testHandler[PublishDiagnosticsParams], diagnostics))

  let progress = FutureStream[ProgressParams]()
  client.registerNotification(
    "$/progress",
    partial(testHandler[ProgressParams], progress))

  let showMessage = FutureStream[ShowMessageParams]()
  client.registerNotification(
    "window/showMessage",
    partial(testHandler[ShowMessageParams], showMessage))

  let initParams = InitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities": {
        "window": {
           "workDoneProgress": true
         },
        "workspace": {"configuration": true}
      }
  }

  discard waitFor client.call("initialize", %initParams)
  client.notify("initialized", newJObject())

  test "Suggest api":
    client.notify("textDocument/didOpen", %createDidOpenParams("projects/hw/hw.nim"))
    let (_, params) = suggestInit.read.waitFor
    doAssert %params ==
      %ProgressParams(
        token: fmt "Creating nimsuggest for {uriToPath(helloWorldUri)}")
    doAssert "begin" == progress.read.waitFor[1].value.get()["kind"].getStr
    doAssert "end" == progress.read.waitFor[1].value.get()["kind"].getStr
    client.notify("textDocument/didOpen",
                  %createDidOpenParams("projects/hw/useRoot.nim"))
    let
      rootNimFileUri = "projects/hw/root.nim".fixtureUri.uriToPath
      rootParams2 = suggestInit.read.waitFor[1]

    doAssert %rootParams2 ==
      %ProgressParams(token: fmt "Creating nimsuggest for {rootNimFileUri}")

    doAssert "begin" == progress.read.waitFor[1].value.get()["kind"].getStr
    doAssert "end" == progress.read.waitFor[1].value.get()["kind"].getStr
    let
      hoverParams = positionParams("projects/hw/hw.nim".fixtureUri, 2, 0)
      hover = client.call("textDocument/hover", %hoverParams).waitFor
    doAssert hover.kind == JNull


suite "LSP features":
  let pipeServer = createPipe();
  let pipeClient = createPipe();

  let
    server = StreamConnection.new(pipeServer)
    inputPipe = asyncPipeInput(pipeClient)
    ls = registerHandlers(server, inputPipe);
  discard server.start(inputPipe);

  let client = StreamConnection.new(pipeClient);
  discard client.start(asyncPipeInput(pipeServer));

  let workspaceConfiguration = %* [{
      "projectMapping": [{
        "projectFile": "missingRoot.nim",
        "fileRegex": "willCrash\\.nim"
      }, {
        "projectFile": "hw.nim",
        "fileRegex": "hw\\.nim"
      }, {
        "projectFile": "root.nim",
        "fileRegex": "useRoot\\.nim"
      }],
      "autoCheckFile": false,
      "autoCheckProject": false
  }]
  let showMessage = FutureStream[ShowMessageParams]()
  client.registerNotification(
    "window/showMessage",
    partial(testHandler[ShowMessageParams], showMessage))


  let configInit = FutureStream[ConfigurationParams]()
  client.register(
    "workspace/configuration",
    partial(testHandler[ConfigurationParams, JsonNode],
            (fut: configInit, res: workspaceConfiguration)))

  let initParams = InitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities": {
          "window": {
            "workDoneProgress": false
          },
        "workspace": {"configuration": true}
      }
  }

  discard waitFor client.call("initialize", %initParams)
  client.notify("initialized", newJObject())

  let didOpenParams = createDidOpenParams("projects/hw/hw.nim")

  client.notify("textDocument/didOpen", %didOpenParams)

  test "Sending hover.":
    let
      hoverParams = positionParams(fixtureUri("projects/hw/hw.nim"), 1, 0)
      hover = client.call("textDocument/hover", %hoverParams).waitFor
      expected = Hover %* {
        "contents": [{
            "language": "nim",
            "value": "hw.a: proc (){.noSideEffect, gcsafe.}"
          }
        ],
        "range": nil
      }
    doAssert %hover == %expected

  test "Sending hover(no content)":
    let
      hoverParams = positionParams( helloWorldUri, 2, 0)
      hover = client.call("textDocument/hover", %hoverParams).waitFor
    doAssert hover.kind == JNull

  test "Definitions.":
    let
      positionParams = positionParams(helloWorldUri, 1, 0)
      locations = to(waitFor client.call("textDocument/definition", %positionParams),
                     seq[Location])
      expected = seq[Location] %* [{
        "uri": helloWorldUri,
        "range": {
          "start": {
            "line": 0,
            "character": 5
          },
          "end": {
            "line": 0,
            "character": 6
          }
        }
      }]
    doAssert %locations == %expected

  test "References.":
    let referenceParams = ReferenceParams %* {
      "context": {
        "includeDeclaration": true
      },
      "position": {
         "line": 1,
         "character": 0
      },
      "textDocument": {
         "uri": helloWorldUri
       }
    }
    let locations = to(waitFor client.call("textDocument/references", %referenceParams),
                       seq[Location])
    let expected = seq[Location] %* [{
      "uri": helloWorldUri,
      "range": {
        "start": {
          "line": 0,
          "character": 5
        },
        "end": {
          "line": 0,
          "character": 6
        }
      }
      }, {
      "uri": helloWorldUri,
      "range": {
        "start": {
          "line": 1,
          "character": 0
        },
        "end": {
          "line": 1,
          "character": 1
        }
      }
    }]
    doAssert %locations == %expected

  test "References(exclude def)":
    let referenceParams =  ReferenceParams %* {
      "context": {
        "includeDeclaration": false
      },
      "position": {
         "line": 1,
         "character": 0
      },
      "textDocument": {
         "uri": helloWorldUri
       }
    }
    let locations = to(waitFor client.call("textDocument/references",
                                            %referenceParams),
                       seq[Location])
    let expected = seq[Location] %* [{
      "uri": helloWorldUri,
      "range": {
        "start": {
          "line": 1,
          "character": 0
        },
        "end": {
          "line": 1,
          "character": 1
        }
      }
    }]
    doAssert %locations == %expected

  test "didChange then sending hover.":
    let didChangeParams = DidChangeTextDocumentParams %* {
      "textDocument": {
        "uri": helloWorldUri,
        "version": 1
      },
      "contentChanges": [{
          "text": "\nproc a() = discard\na()\n"
        }
      ]
    }

    client.notify("textDocument/didChange", %didChangeParams)
    let
      hoverParams = positionParams(fixtureUri("projects/hw/hw.nim"), 2, 0)
      hover = to(waitFor client.call("textDocument/hover",
                                               %hoverParams),
                 Hover)
      expected = Hover %* {
        "contents": [{
            "language": "nim",
            "value": "hw.a: proc (){.noSideEffect, gcsafe.}"
          }
        ],
        "range": nil
      }

    doAssert %hover == %expected

  test "Completion":
    let completionParams = CompletionParams %* {
      "position": {
         "line": 3,
         "character": 2
      },
      "textDocument": {
         "uri": fixtureUri("projects/hw/hw.nim")
       }
    }
    let actualEchoCompletionItem =
      to(waitFor client.call("textDocument/completion", %completionParams),
         seq[CompletionItem])
      .filter(item => item.label == "echo")[0]

    let expected = CompletionItem %* {
      "label": "echo",
      "kind": 3,
      "detail": "proc (x: varargs[typed]){.gcsafe.}",
    }

    doAssert actualEchoCompletionItem.label == expected.label
    doAssert actualEchoCompletionItem.kind == expected.kind
    doAssert actualEchoCompletionItem.detail == expected.detail
    doAssert actualEchoCompletionItem.documentation != expected.documentation

  test "Shutdown":
    let
      nullValue = newJNull()
      nullResponse = waitFor client.call("shutdown", nullValue)

    doAssert nullResponse == nullValue
    doAssert ls.isShutdown

  pipeClient.close()
  pipeServer.close()

proc ignore(params: JsonNode): Future[void] {.async.} = return

suite "Null configuration:":
  let pipeServer = createPipe();
  let pipeClient = createPipe();

  let
    server = StreamConnection.new(pipeServer)
    inputPipe = asyncPipeInput(pipeClient)
  discard registerHandlers(server, inputPipe);
  discard server.start(inputPipe);

  let client = StreamConnection.new(pipeClient);
  discard client.start(asyncPipeInput(pipeServer));
  let workspaceConfiguration = %* [nil]

  let configInit = FutureStream[ConfigurationParams]()
  client.register(
    "workspace/configuration",
    partial(testHandler[ConfigurationParams, JsonNode],
            (fut: configInit, res: workspaceConfiguration)))

  client.registerNotification("textDocument/publishDiagnostics", ignore)
  client.registerNotification("window/showMessage", ignore)

  let initParams = InitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities": {
        "workspace": {"configuration": true}
      }
  }

  discard waitFor client.call("initialize", %initParams)
  client.notify("initialized", newJObject())

  test "Null configuration":
    client.notify("textDocument/didOpen", %createDidOpenParams("projects/hw/hw.nim"))
    let hoverParams = positionParams("projects/hw/hw.nim".fixtureUri, 2, 0)
    let hover = client.call("textDocument/hover", %hoverParams).waitFor
    doAssert hover.kind == JNull

suite "LSP expand":
  let pipeServer = createPipe();
  let pipeClient = createPipe();

  let
    server = StreamConnection.new(pipeServer)
    inputPipe = asyncPipeInput(pipeClient)
  discard registerHandlers(server, inputPipe);
  discard server.start(inputPipe);

  let client = StreamConnection.new(pipeClient);
  discard client.start(asyncPipeInput(pipeServer));

  let workspaceConfiguration = %* [{
      "projectMapping": [{
        "projectFile": "missingRoot.nim",
        "fileRegex": "willCrash\\.nim"
      }, {
        "projectFile": "hw.nim",
        "fileRegex": "hw\\.nim"
      }, {
        "projectFile": "root.nim",
        "fileRegex": "useRoot\\.nim"
      }],
      "autoCheckFile": false,
      "autoCheckProject": false
  }]
  let showMessage = FutureStream[ShowMessageParams]()
  client.registerNotification(
    "window/showMessage",
    partial(testHandler[ShowMessageParams], showMessage))


  let configInit = FutureStream[ConfigurationParams]()
  client.register(
    "workspace/configuration",
    partial(testHandler[ConfigurationParams, JsonNode],
            (fut: configInit, res: workspaceConfiguration)))

  let initParams = InitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities": {
          "window": {
            "workDoneProgress": false
          },
        "workspace": {"configuration": true}
      }
  }

  discard waitFor client.call("initialize", %initParams)
  client.notify("initialized", newJObject())

  let didOpenParams = createDidOpenParams("projects/hw/hw.nim")

  client.notify("textDocument/didOpen", %didOpenParams)

  test "Expand nested":
    let expandParams2 = ExpandTextDocumentPositionParams %* {
      "position": {
         "line": 27,
         "character": 2
      },
      "textDocument": {
         "uri": helloWorldUri
       },
      "level": 1
    }
    let expandResult2 =
      to(client.call("extension/macroExpand", %expandParams2).waitFor,
         ExpandResult)
    let expected2 = ExpandResult %* {
      "range":{
        "start":{"line":27,"character":0},
        "end":{"line":28,"character":19}},
      "content":"  block:\n    template field1(): untyped =\n      a.field1\n\n    template field2(): untyped =\n      a.field2\n\n    a.field1 = a.field2"
    }

    doAssert %expected2 == %expandResult2

  test "Expand":
    let expandParams = ExpandTextDocumentPositionParams %* {
      "position": {
         "line": 16,
         "character": 0
      },
      "textDocument": {
         "uri": helloWorldUri
       },
      "level": 1
    }
    var expandResult =
      to(client.call("extension/macroExpand", %expandParams).waitFor,
         ExpandResult)
    var expected = ExpandResult %*
       {
         "range": {
           "start":{
             "line":16,
             "character":0
           },
           "end":{
             "line":17,
             "character":9
           }},
         "content":"proc helloProc(): string =\n  result = \"Hello\"\n"
       }
    doAssert %expected == %expandResult
