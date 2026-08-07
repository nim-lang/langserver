import std/[options, json, os, jsonutils, sequtils, strutils, sugar, strformat]

import ../src/quicknimlsp
import ../src/langserver/[langserver, langserver_types, utils]
import ../src/utils/utils
import ../src/protocol/[enums, types]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient
import unittest2

suite "LSP features (failing)":
  let helloWorldUri = fixtureUri("projects/hw/hw.nim")
  let cmdParams = CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  client.registerNotification(
    "window/showMessage",
    "window/workDoneProgress/create",
    "workspace/configuration",
    "extension/statusUpdate",
    "textDocument/publishDiagnostics",
    "$/progress"
  )
  waitFor client.connect("localhost", cmdParams.port)

  let initParams = LspInitializeParams %* {
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
  discard waitFor client.waitForNotificationMessage(
    fmt"Nimsuggest initialized for {uriToPath(helloWorldUri)}",
  )

  test "didChange then sending hover.":
    echo "    >> didChange then sending hover."
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
    sleep(1000)
    let hoverParams = positionParams(fixtureUri("projects/hw/hw.nim"), 2, 0)
    # echo "HOVER PARAMS ", $hoverParams
    let hoverResponse = client.call("textDocument/hover", %hoverParams).waitFor
    echo "hover response ", $hoverResponse
    check contains($hoverResponse, "hw.a: proc ()")
