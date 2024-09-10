import ../[
  nimlangserver, ls, lstransports, utils
]
import ../protocol/[enums, types]
import std/[options, unittest, json, os, jsonutils, sequtils, strutils, sugar, strformat]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient


suite "Nimlangserver":
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  
  test "initialize from the client should call initialized on the server":
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
    let initializeResult = waitFor client.initialize(initParams)
    
    check initializeResult.capabilities.textDocumentSync.isSome


let helloWorldUri = fixtureUri("projects/hw/hw.nim")

  
suite "Suggest API selection":
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  client.registerNotification(
    "window/showMessage", 
    "window/workDoneProgress/create",
    "workspace/configuration",
    "extension/statusUpdate",
    "extension/statusUpdate",
    "textDocument/publishDiagnostics",
    "$/progress"
    )

  
  waitFor client.connect("localhost", cmdParams.port)
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
  discard waitFor client.initialize(initParams)
  client.notify("initialized", newJObject())

  test "Suggest api":
    #The client adds the notifications into the call table and we wait until they arrived.   
    let helloWorldFile = "projects/hw/hw.nim"    
    client.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile))

    let progressParam = %ProgressParams(token: fmt "Creating nimsuggest for {uriToPath(helloWorldFile.fixtureUri())}")
    check waitFor client.waitForNotification("$/progress", (json: JsonNode) => progressParam["token"] == json["token"])
    check waitFor client.waitForNotification("$/progress", (json: JsonNode) => json["value"]["kind"].getStr == "begin")
    check waitFor client.waitForNotification("$/progress", (json: JsonNode) => json["value"]["kind"].getStr == "end")

    client.notify("textDocument/didOpen",
                  %createDidOpenParams("projects/hw/useRoot.nim"))
    let
      hoverParams = positionParams("projects/hw/hw.nim".fixtureUri, 2, 0)
      hover = client.call("textDocument/hover", %hoverParams).waitFor
    check hover.kind == JNull

suite "LSP features":
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  client.registerNotification(
    "window/showMessage", 
    "window/workDoneProgress/create",
    "workspace/configuration",
    "extension/statusUpdate",
    "extension/statusUpdate",
    "textDocument/publishDiagnostics",
    "$/progress"
    )

  waitFor client.connect("localhost", cmdParams.port)

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

  discard waitFor client.initialize(initParams)

  client.notify("initialized", newJObject())
  let didOpenParams = createDidOpenParams("projects/hw/hw.nim")

  client.notify("textDocument/didOpen", %didOpenParams)

  test "Sending hover.":
    let
      hoverParams = positionParams(fixtureUri("projects/hw/hw.nim"), 1, 0)
      hover = client.call("textDocument/hover", %hoverParams).waitFor
    doAssert contains($hover, "hw.a: proc ()")

  test "Sending hover(no content)":
    let
      hoverParams = positionParams(helloWorldUri, 2, 0)
      hover = client.call("textDocument/hover", %hoverParams).waitFor
    check hover.kind == JNull

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
    check %locations == %expected

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
    check %locations == %expected

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
    check %locations == %expected

  test "Prepare rename":
    let renameParams = PrepareRenameParams(
      textDocument: TextDocumentIdentifier(uri: helloWorldUri),
      position: Position(line: 2, character: 6)
    )
    let resp = client.call("textDocument/prepareRename", %renameParams)
                        .waitFor()
    check resp == %* {
        "start":{"line":2,"character":4},
        "end":{"line":2,"character":7}
    }


  test "Prepare rename doesn't allow non-project symbols":
    let renameParams = PrepareRenameParams(
      textDocument: TextDocumentIdentifier(uri: helloWorldUri),
      position: Position(line: 8, character: 10)
    )
    let resp = client.call("textDocument/prepareRename", %renameParams)
                        .waitFor()
    check resp.kind == JNull

  test "Rename":
    let renameParams = RenameParams(
        textDocument: TextDocumentIdentifier(uri: helloWorldUri),
        newName: "hello",
        position: Position(line: 2, character: 6)
    )
    let changes = client.call("textDocument/rename", %renameParams)
                        .waitFor().to(WorkSpaceEdit).changes.get()
    check changes.len == 1
    check changes[helloWorldUri].len == 3
    check changes[helloWorldUri].mapIt(it["newText"].getStr()) == @["hello", "hello", "hello"]

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
      hover = client.call("textDocument/hover", %hoverParams).waitFor
    doAssert contains($hover, "hw.a: proc ()")

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

    doAssert actualEchoCompletionItem.label == "echo"
    doAssert actualEchoCompletionItem.kind.get == 3
    doAssert actualEchoCompletionItem.detail.get().contains("proc")
    doAssert actualEchoCompletionItem.documentation.isSome

  test "Shutdown":
    let
      nullValue = newJNull()
      nullResponse = waitFor client.call("shutdown", nullValue)

    doAssert nullResponse == nullValue
    doAssert ls.isShutdown    

suite "Null configuration:":
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  client.registerNotification(
    "window/showMessage", 
    "window/workDoneProgress/create",
    "workspace/configuration",
    "extension/statusUpdate",
    "extension/statusUpdate",
    "textDocument/publishDiagnostics",
    "$/progress"
    )
  
  waitFor client.connect("localhost", cmdParams.port)

  let initParams = InitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities": {
        "workspace": {"configuration": true},
        "textDocument": {
          "rename": {
            "prepareSupport": true
          }
        }
      }
  }

  discard waitFor client.initialize(initParams)
  client.notify("initialized", newJObject())

  test "Null configuration":
    client.notify("textDocument/didOpen", %createDidOpenParams("projects/hw/hw.nim"))
    let hoverParams = positionParams("projects/hw/hw.nim".fixtureUri, 2, 0)
    let hover = client.call("textDocument/hover", %hoverParams).waitFor
    doAssert hover.kind == JNull
