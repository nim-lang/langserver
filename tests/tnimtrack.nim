import ../[nimlangserver, ls, lstransports, utils]
import ../protocol/[enums, types]
import std/[options, json, os, osproc, jsonutils, sequtils, strutils, strformat]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient
import unittest2

suite "Nim track with nim >= 2.3.1":
  let trackProjectDir = absolutePath("tests" / "projects" / "trackproject")
  let savedDir = getCurrentDir()
  setCurrentDir(trackProjectDir)
  discard execCmdEx("nimble install -l -y")
  discard execCmdEx("nimble setup")
  setCurrentDir(savedDir)

  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  client.registerNotification(
    "window/showMessage", "extension/statusUpdate", "textDocument/publishDiagnostics",
    "$/progress",
  )
  waitFor client.connect("localhost", cmdParams.port)

  let conf = NlsConfig(useNimTrack: some true)
  ls.workspaceConfiguration = newFuture[JsonNode]()
  ls.workspaceConfiguration.complete(% @[conf])

  let initParams =
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/trackproject/"),
      "capabilities": {"window": {"workDoneProgress": false}},
    }
  discard waitFor client.initialize(initParams)

  let trackFile = "projects/trackproject/src/trackproject.nim"
  client.notify("textDocument/didOpen", %createDidOpenParams(trackFile))

  let trackAbsFile = trackFile.fixtureUri.uriToPath
  check waitFor client.waitForNotificationMessage(
    fmt"Nimsuggest initialized for {trackAbsFile}"
  )

  let trackUri = fixtureUri("projects/trackproject/src/trackproject.nim")

  test "Definition with nim track":
    client.notify("textDocument/didOpen", %createDidOpenParams(trackFile))
    discard waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {trackAbsFile}"
    )
    let
      positionParams = positionParams(trackUri, 4, 6)
      locations = to(
        waitFor client.call("textDocument/definition", %positionParams), seq[Location]
      )
    check locations.len == 1
    check locations[0].uri.pathToUri().contains("trackproject.nim")

  test "References with nim track":
    client.notify("textDocument/didOpen", %createDidOpenParams(trackFile))
    discard waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {trackAbsFile}"
    )
    let referenceParams =
      ReferenceParams %* {
        "context": {"includeDeclaration": false},
        "position": {"line": 4, "character": 6},
        "textDocument": {"uri": trackUri},
      }
    let locations = to(
      waitFor client.call("textDocument/references", %referenceParams), seq[Location]
    )
    check locations.len >= 1

suite "Nim track unavailable with nim < 2.3.1":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  client.registerNotification(
    "window/showMessage", "extension/statusUpdate", "textDocument/publishDiagnostics",
    "$/progress",
  )
  waitFor client.connect("localhost", cmdParams.port)

  let conf = NlsConfig(useNimTrack: some true)
  ls.workspaceConfiguration = newFuture[JsonNode]()
  ls.workspaceConfiguration.complete(% @[conf])

  let initParams =
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities": {"window": {"workDoneProgress": false}},
    }
  discard waitFor client.initialize(initParams)

  let hwFile = "projects/hw/hw.nim"
  client.notify("textDocument/didOpen", %createDidOpenParams(hwFile))

  let hwAbsFile = hwFile.fixtureUri.uriToPath
  check waitFor client.waitForNotificationMessage(
    fmt"Nimsuggest initialized for {hwAbsFile}"
  )

  let hwUri = fixtureUri("projects/hw/hw.nim")

  test "Definition returns empty":
    let
      positionParams = positionParams(hwUri, 1, 6)
      locations = to(
        waitFor client.call("textDocument/definition", %positionParams), seq[Location]
      )
    check locations.len == 0

  test "References returns empty":
    let referenceParams =
      ReferenceParams %* {
        "context": {"includeDeclaration": false},
        "position": {"line": 1, "character": 6},
        "textDocument": {"uri": hwUri},
      }
    let locations = to(
      waitFor client.call("textDocument/references", %referenceParams), seq[Location]
    )
    check locations.len == 0
