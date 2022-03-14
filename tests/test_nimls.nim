import
  ../nimls,
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

  let server = StreamConnection.new(pipeServer);
  registerHandlers(server);
  discard server.start(asyncPipeInput(pipeClient));

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

  let server = StreamConnection.new(pipeServer);
  registerHandlers(server);
  discard server.start(asyncPipeInput(pipeClient));

  let client = StreamConnection.new(pipeClient);
  discard client.start(asyncPipeInput(pipeServer));

  let suggestInit = FutureStream[ProgressParams]()
  client.register("window/workDoneProgress/create",
                            partial(testHandler[ProgressParams, JsonNode],
                                    (fut: suggestInit, res: newJNull())))
  let workspaceConfiguration = %* [{
      "rootConfig": [{
        "root": "missingRoot.nim",
        "regexps": ["willCrash\\.nim"]
      }, {
        "root": "hw.nim",
        "regexps": ["hw\\.nim"]
      }, {
        "root": "root.nim",
        "regexps": ["root\\.nim", "useRoot\\.nim"]
      }]
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

  test "Crashing nimsuggest":
    client.notify("textDocument/didOpen",
                  %createDidOpenParams("projects/hw/willCrash.nim"))
    let params = suggestInit.read.waitFor[1]
    doAssert %params ==
      %ProgressParams(
        token: fmt "Creating nimsuggest for {\"projects/hw/missingRoot.nim\".fixtureUri.uriToPath}")

    let
      hoverParams = positionParams("projects/hw/willCrash.nim".fixtureUri, 1, 0)
      hover = client.call("textDocument/hover", %hoverParams)
                .waitFor
                .to(Hover)
    doAssert hover == nil

    let actual = client.call(
        "textDocument/codeAction", %* {
          "range": range(1, 1, 1, 1),
          "textDocument": {
            "uri": fixtureUri("projects/hw/willCrash.nim")
          },
          "context": {
            "diagnostics": @[]
          }
        })
      .waitFor
      .to(seq[CodeAction])

    let expected = seq[CodeAction] %* [{
      "command": {
        "title": "Restart nimsuggest",
        "command": "nimls.restart",
        "arguments": @[uriToPath fixtureUri "projects/hw/missingRoot.nim"]
      },
      "title": "Restart nimsuggest",
      "kind": "source"
    }]

    doAssert %actual == %expected

    doAssert %diagnostics.read.waitFor[1] ==  %* {
      "uri": helloWorldUri,
      "diagnostics":[{
        "range":{
          "start":{
            "line":4,
            "character":6
          },
          "end":{
            "line":4,
            "character":45
          }
        },
        "severity": 1,
        "code": "nimsuggest chk",
        "source": "nim",
        "message": "type mismatch: got 'string' for '\"\"' but expected 'int'",
        "relatedInformation":nil
      }]
    }

    # clear errors after did save
    client.notify("textDocument/didChange", %* {
      "textDocument": {
        "uri": helloWorldUri,
        "version": 1
      },
      "contentChanges": [{
          "text": "echo \"Hello, world!\" "
        }
      ]
    })
    client.notify("textDocument/didSave", %* {
      "textDocument": {
        "uri": helloWorldUri,
        "version": 1
      }
    })

    doAssert %diagnostics.read.waitFor[1] == %* {
      "uri": helloWorldUri,
      "diagnostics":[]
    }

suite "LSP features":
  let pipeServer = createPipe();
  let pipeClient = createPipe();

  let server = StreamConnection.new(pipeServer);
  registerHandlers(server);
  discard server.start(asyncPipeInput(pipeClient));

  let client = StreamConnection.new(pipeClient);
  discard client.start(asyncPipeInput(pipeServer));

  let initParams = InitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities": {
          "window": {
            "workDoneProgress": false
          }
      }
  }

  discard waitFor client.call("initialize", %initParams)
  client.notify("initialized", newJObject())

  let didOpenParams = createDidOpenParams("projects/hw/hw.nim")

  client.notify("textDocument/didOpen", %didOpenParams)

  test "Sending hover.":
    let
      hoverParams = positionParams(fixtureUri("projects/hw/hw.nim"), 1, 0)
      hover = client.call("textDocument/hover", %hoverParams).waitFor.to(Hover)
      expected = Hover %* {
        "contents": [{
            "language": "nim",
            "value": "hw.a: proc (){.noSideEffect, gcsafe, locks: 0.}"
          }
        ],
        "range": nil
      }
    doAssert %hover == %expected

  test "Sending hover(no content)":
    let
      hoverParams = positionParams( helloWorldUri, 2, 0)
      hover = waitFor client.call("textDocument/hover", %hoverParams)
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
            "value": "hw.a: proc (){.noSideEffect, gcsafe, locks: 0.}"
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
      "detail": "proc (x: varargs[typed]){.gcsafe, locks: 0.}",
      "documentation": """Writes and flushes the parameters to the standard output.

Special built-in that takes a variable number of arguments. Each argument
is converted to a string via `$`, so it works for user-defined
types that have an overloaded `$` operator.
It is roughly equivalent to `writeLine(stdout, x); flushFile(stdout)`, but
available for the JavaScript target too.

Unlike other IO operations this is guaranteed to be thread-safe as
`echo` is very often used for debugging convenience. If you want to use
`echo` inside a `proc without side effects
<manual.html#pragmas-nosideeffect-pragma>`_ you can use `debugEcho
<#debugEcho,varargs[typed,]>`_ instead."""
    }

    doAssert %actualEchoCompletionItem == %expected

  pipeClient.close()
  pipeServer.close()
