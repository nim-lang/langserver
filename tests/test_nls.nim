import
  std/json,
  os,
  sequtils,
  sugar,
  unittest,
  jsonschema,
  json_rpc/jsonmarshal,
  faststreams/async_backend,
  faststreams/asynctools_adapters,
  json_rpc/streamconnection,
  ../nls,
  ../protocol/types

proc fixtureUri(path: string): string =
  result = pathToUri(getCurrentDir() / "tests" / path)

suite "Client/server initialization sequence":
  let pipeServer = createPipe();
  let pipeClient = createPipe();

  let serverConnection = StreamConnection.new(pipeClient, pipeServer);
  registerLanguageServerHandlers(serverConnection);
  discard serverConnection.start();

  let clientConnection = StreamConnection.new(pipeServer, pipeClient);
  discard clientConnection.start();

  test "Sending initialize.":
    let initParams = InitializeParams(
        processId: %getCurrentProcessId(),
        rootUri: "file:///tmp/",
        capabilities: ClientCapabilities())

    let initializeResult = waitFor clientConnection.call("initialize", %initParams)
    doAssert initializeResult != nil;

    waitFor clientConnection.notify("initialized", newJObject())

  pipeClient.close()
  pipeServer.close()


suite "LSP features":
  let pipeServer = createPipe();
  let pipeClient = createPipe();

  let serverConnection = StreamConnection.new(pipeClient, pipeServer);
  registerLanguageServerHandlers(serverConnection);
  discard serverConnection.start();

  let clientConnection = StreamConnection.new(pipeServer, pipeClient);
  discard clientConnection.start();

  let initParams = InitializeParams(
      processId: %getCurrentProcessId(),
      rootUri: fixtureUri("projects/hw/"),
      capabilities: ClientCapabilities())

  discard waitFor clientConnection.call("initialize", %initParams)
  waitFor clientConnection.notify("initialized", newJObject())

  let didOpenParams = DidOpenTextDocumentParams %* {
    "textDocument": {
      "uri": fixtureUri("projects/hw/hw.nim"),
      "languageId": "nim",
      "version": 0,
      "text": readFile("tests/projects/hw/hw.nim")
     }
   }

  discard clientConnection.notify("textDocument/didOpen", %didOpenParams)

  let helloWorldUri = fixtureUri("projects/hw/hw.nim")

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

    discard clientConnection.notify("textDocument/didChange", %didChangeParams)
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
      "kind": 10,
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
