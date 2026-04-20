import ../[nimlangserver, ls, lstransports, utils]
import ../protocol/[enums, types]
import std/[options, json, os, jsonutils, sequtils, strutils, sugar, strformat]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient
import unittest2

# This test verifies the nim/traceExpandMacro command integration.
#
# To test manually:
#   1. Start the langserver
#   2. Initialize with a project containing macros
#   3. Send workspace/executeCommand with:
#      {
#        "command": "nim/traceExpandMacro",
#        "arguments": [{"uri": "<file-uri>", "line": <line>, "character": <col>}]
#      }
#   4. Verify the response contains {"tracePath": "<path-to-.ct-file>"}
#
# The traceExpandMacro command can also be called directly as a custom request:
#   Method: "nim/traceExpandMacro"
#   Params: {"textDocument": {"uri": "<file-uri>"}, "position": {"line": <line>, "character": <col>}}
#
# Note: This requires a nimsuggest binary that supports the `traceExpand` command.
# Older versions of nimsuggest will return an error.

suite "TraceExpandMacro":
  let cmdParams = CommandLineParams(transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  client.registerNotification(
    "window/showMessage",
    "window/workDoneProgress/create",
    "workspace/configuration",
    "extension/statusUpdate",
    "textDocument/publishDiagnostics",
    "$/progress",
  )
  waitFor client.connect("localhost", cmdParams.port)

  let initParams =
    InitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities": {
        "window": {"workDoneProgress": true}, "workspace": {"configuration": true}
      },
    }
  let initResult = waitFor client.initialize(initParams)
  client.notify("initialized", newJObject())

  test "traceExpandMacro command is registered in server capabilities":
    let commands = initResult.capabilities.executeCommandProvider.get.commands.get
    check "nim/traceExpandMacro" in commands

  test "traceExpandMacro via workspace/executeCommand on non-macro returns error":
    let helloWorldFile = "projects/hw/hw.nim"
    client.notify("textDocument/didOpen", %createDidOpenParams(helloWorldFile))

    let hwAbsFile = helloWorldFile.fixtureUri.uriToPath
    check waitFor client.waitForNotificationMessage(
      fmt "Nimsuggest initialized for {hwAbsFile}"
    )

    # Call traceExpandMacro on a position that is not a macro (line 1, col 0 of hw.nim)
    # This should fail gracefully since hw.nim likely doesn't have macros at that position
    let executeParams = %*{
      "command": "nim/traceExpandMacro",
      "arguments": [{"uri": fixtureUri(helloWorldFile), "line": 0, "character": 0}],
    }
    var gotError = false
    try:
      let res = waitFor client.call("workspace/executeCommand", executeParams)
      # If nimsuggest doesn't support traceExpand, we get an error
      # If it does but position is not a macro, we also get an error
      # Both are acceptable outcomes for this test
      if res.kind == JObject and res.hasKey("tracePath"):
        # Unexpected success - the position happened to be a macro
        discard
      else:
        gotError = true
    except CatchableError:
      gotError = true
    # We expect either an error (no macro at position) or
    # an error (nimsuggest doesn't support traceExpand)
    check gotError

  test "traceExpandMacro direct call on non-macro returns error":
    let helloWorldFile = "projects/hw/hw.nim"
    let traceParams = %*{
      "textDocument": {"uri": fixtureUri(helloWorldFile)},
      "position": {"line": 0, "character": 0},
    }
    var gotError = false
    try:
      let res = waitFor client.call("nim/traceExpandMacro", traceParams)
      if res.kind != JObject or not res.hasKey("tracePath") or
          res["tracePath"].getStr == "":
        gotError = true
    except CatchableError:
      gotError = true
    check gotError
