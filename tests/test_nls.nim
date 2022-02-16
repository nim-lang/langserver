import
  ../nls,
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

  let serverConnection = StreamConnection.new(pipeServer);
  registerHandlers(serverConnection);
  discard serverConnection.start(asyncPipeInput(pipeClient));

  let clientConnection = StreamConnection.new(pipeClient);
  discard clientConnection.start(asyncPipeInput(pipeServer));

  test "Sending initialize.":
    let initParams = InitializeParams(
        processId: %getCurrentProcessId(),
        rootUri: "file:///tmp/",
        capabilities: ClientCapabilities())

    let initializeResult = waitFor clientConnection.call("initialize", %initParams)
    doAssert initializeResult != nil;

    clientConnection.notify("initialized", newJObject())

  pipeClient.close()
  pipeServer.close()

proc testHandler[T, Q](input: tuple[fut: FutureStream[T], res: Q], arg: T): Future[Q] {.async, gcsafe.} =
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

suite "Suggest API selection":
  let pipeServer = createPipe();
  let pipeClient = createPipe();

  let serverConnection = StreamConnection.new(pipeServer);
  registerHandlers(serverConnection);
  discard serverConnection.start(asyncPipeInput(pipeClient));

  let clientConnection = StreamConnection.new(pipeClient);
  discard clientConnection.start(asyncPipeInput(pipeServer));

  let suggestInit = FutureStream[ProgressParams]()
  clientConnection.register("window/workDoneProgress/create",
                            partial(testHandler[ProgressParams, JsonNode],
                                    (fut: suggestInit, res: newJNull())))
  let workspaceConfiguration = %* [{
      "nimsuggest": [{
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
  clientConnection.register(
    "workspace/configuration",
    partial(testHandler[ConfigurationParams, JsonNode],
            (fut: configInit, res: workspaceConfiguration)))

  let diagnosticsParams = FutureStream[PublishDiagnosticsParams]()
  clientConnection.registerNotification(
    "textDocument/publishDiagnostics",
    partial(testHandler[PublishDiagnosticsParams], diagnosticsParams))

  let progress = FutureStream[ProgressParams]()
  clientConnection.registerNotification(
    "$/progress",
    partial(testHandler[ProgressParams], progress))

  let showMessage = FutureStream[ShowMessageParams]()
  clientConnection.registerNotification(
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

  discard waitFor clientConnection.call("initialize", %initParams)
  clientConnection.notify("initialized", newJObject())

  test "Suggest api":
    clientConnection.notify("textDocument/didOpen",
                            %createDidOpenParams("projects/hw/hw.nim"))
    let (_, params) = suggestInit.read.waitFor
    doAssert %params ==
      %ProgressParams(
        token: fmt "Creating nimsuggest for {uriToPath(helloWorldUri)}")
    doAssert "begin" == progress.read.waitFor[1].value.get()["kind"].getStr
    doAssert "end" == progress.read.waitFor[1].value.get()["kind"].getStr

    clientConnection.notify("textDocument/didOpen",
                            %createDidOpenParams("projects/hw/useRoot.nim"))
    let
      rootNimFileUri = "projects/hw/root.nim".fixtureUri.uriToPath
      rootParams2 = suggestInit.read.waitFor[1]

    doAssert %rootParams2 ==
      %ProgressParams(token: fmt "Creating nimsuggest for {rootNimFileUri}")

    doAssert "begin" == progress.read.waitFor[1].value.get()["kind"].getStr
    doAssert "end" == progress.read.waitFor[1].value.get()["kind"].getStr

  test "Crashing nimsuggest":
    clientConnection.notify("textDocument/didOpen",
                            %createDidOpenParams("projects/hw/willCrash.nim"))
    let params = suggestInit.read.waitFor[1]
    doAssert %params ==
      %ProgressParams(
        token: fmt "Creating nimsuggest for {\"projects/hw/missingRoot.nim\".fixtureUri.uriToPath}")

    let hoverParams = HoverParams %* {
      "position": {
         "line": 1,
         "character": 0
      },
      "textDocument": {
         "uri": "projects/hw/willCrash.nim".fixtureUri
       }
    }

    let hover = to(waitFor clientConnection.call("textDocument/hover",
                                                 %hoverParams),
                   Hover)
    doAssert hover == nil

suite "LSP features":
  let pipeServer = createPipe();
  let pipeClient = createPipe();

  let serverConnection = StreamConnection.new(pipeServer);
  registerHandlers(serverConnection);
  discard serverConnection.start(asyncPipeInput(pipeClient));

  let clientConnection = StreamConnection.new(pipeClient);
  discard clientConnection.start(asyncPipeInput(pipeServer));


  let initParams = InitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities": {
          "window": {
            "workDoneProgress": false
          }
      }
  }

  discard waitFor clientConnection.call("initialize", %initParams)
  clientConnection.notify("initialized", newJObject())

  let didOpenParams = createDidOpenParams("projects/hw/hw.nim")

  clientConnection.notify("textDocument/didOpen", %didOpenParams)

  test "Sending hover.":
    let hoverParams = HoverParams %* {
      "position": {
         "line": 1,
         "character": 0
      },
      "textDocument": {
         "uri": fixtureUri("projects/hw/hw.nim")
       }
    }
    let hover = to(waitFor clientConnection.call("textDocument/hover",
                                                 %hoverParams),
                   Hover)
    let expected = Hover %* {
      "contents": [{
          "language": "nim",
          "value": "hw.a: proc (){.noSideEffect, gcsafe, locks: 0.}"
        }
      ],
      "range": nil
    }

    doAssert %hover == %expected

  test "Sending hover(no content)":
    let hoverParams = HoverParams %* {
      "position": {
         "line": 2,
         "character": 0
      },
      "textDocument": {
         "uri": helloWorldUri
       }
    }
    let hover = waitFor clientConnection.call("textDocument/hover", %hoverParams)
    doAssert hover.kind == JNull

  test "Definitions.":
    let positionParams = TextDocumentPositionParams %* {
      "position": {
         "line": 1,
         "character": 0
      },
      "textDocument": {
         "uri": helloWorldUri
       }
    }
    let locations = to(waitFor clientConnection.call("textDocument/definition",
                                                     %positionParams),
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
    let locations = to(waitFor clientConnection.call("textDocument/references",
                                                     %referenceParams),
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
    let locations = to(waitFor clientConnection.call("textDocument/references",
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

    clientConnection.notify("textDocument/didChange", %didChangeParams)
    let hoverParams = HoverParams %* {
      "position": {
         "line": 2,
         "character": 0
      },
      "textDocument": {
         "uri": fixtureUri("projects/hw/hw.nim")
       }
    }
    let hover = to(waitFor clientConnection.call("textDocument/hover",
                                                 %hoverParams),
                   Hover)
    let expected = Hover %* {
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
      to(waitFor clientConnection.call("textDocument/completion",
                                       %completionParams),
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
