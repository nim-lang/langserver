import ../[nimlangserver, ls, lstransports, utils]
import ../protocol/[enums, types]
import std/[options, json, os, jsonutils, sequtils, strutils, sugar, strformat]
import json_rpc/[rpcclient]
import chronicles
import lspsocketclient
import unittest2

# NOTE: The success path (test 4) requires a nimsuggest binary that supports
# the `traceExpand` command. If the installed nimsuggest does not support it,
# that test will SKIP rather than pass or fail. We cannot verify .ct file
# content from tests because trace-enabled nimsuggest may not be available
# in all CI environments.

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
      "rootUri": fixtureUri("projects/macrotest/"),
      "capabilities": {
        "window": {"workDoneProgress": true}, "workspace": {"configuration": true}
      },
    }
  let initResult = waitFor client.initialize(initParams)
  client.notify("initialized", newJObject())

  test "traceExpandMacro command is registered in server capabilities":
    let commands = initResult.capabilities.executeCommandProvider.get.commands.get
    check "nim/traceExpandMacro" in commands

  test "traceExpandMacro on non-macro position returns error":
    # Open the macro test file and wait for nimsuggest to initialize
    let macroFile = "projects/macrotest/macrotest.nim"
    client.notify("textDocument/didOpen", %createDidOpenParams(macroFile))

    let absFile = macroFile.fixtureUri.uriToPath
    check waitFor client.waitForNotificationMessage(
      fmt "Nimsuggest initialized for {absFile}"
    )

    # Position (9, 0) is `echo "hello"` - not a macro call
    # The server should return a descriptive error, not crash
    let traceParams = %*{
      "textDocument": {"uri": fixtureUri(macroFile)},
      "position": {"line": 9, "character": 0},
    }
    var gotError = false
    var errorMsg = ""
    try:
      let res = waitFor client.call("nim/traceExpandMacro", traceParams)
      # If we get a response, it should NOT have a valid tracePath
      # (since this position is not a macro)
      if res.kind == JNull:
        gotError = true
      elif res.kind == JObject:
        if not res.hasKey("tracePath") or res["tracePath"].getStr == "":
          gotError = true
        # else: unexpectedly got a trace path for a non-macro - test fails
    except CatchableError as e:
      gotError = true
      errorMsg = e.msg
    check gotError

  test "traceExpandMacro on invalid file returns error":
    # Send command with a non-existent file URI - should error gracefully
    let traceParams = %*{
      "textDocument": {"uri": "file:///nonexistent/path/fake.nim"},
      "position": {"line": 0, "character": 0},
    }
    var gotError = false
    try:
      let res = waitFor client.call("nim/traceExpandMacro", traceParams)
      # Any non-tracePath response is acceptable as an error indication
      if res.kind == JNull:
        gotError = true
      elif res.kind == JObject:
        if not res.hasKey("tracePath") or res["tracePath"].getStr == "":
          gotError = true
    except CatchableError:
      gotError = true
    check gotError

  test "traceExpandMacro on macro call position returns trace path or skips if unsupported":
    # Position (6, 0) is `myMacro:` - the macro invocation
    let macroFile = "projects/macrotest/macrotest.nim"
    let traceParams = %*{
      "textDocument": {"uri": fixtureUri(macroFile)},
      "position": {"line": 6, "character": 0},
    }
    var gotTracePath = false
    var nimsuggestUnsupported = false
    var otherError = ""
    try:
      let res = waitFor client.call("nim/traceExpandMacro", traceParams)
      if res.kind == JObject and res.hasKey("tracePath"):
        let tracePath = res["tracePath"].getStr
        # Verify the trace path looks correct
        check tracePath.endsWith(".ct")
        check tracePath.len > 3  # Not just ".ct"
        gotTracePath = true
      else:
        # Got a response but no tracePath - could mean nimsuggest doesn't support it
        # or the position wasn't recognized as a macro
        otherError = "Response did not contain tracePath: " & $res
    except CatchableError as e:
      if "traceExpand" in e.msg or "not support" in e.msg:
        nimsuggestUnsupported = true
      elif "No trace result" in e.msg or "not a macro" in e.msg:
        # nimsuggest supports traceExpand but didn't find a macro at this position
        # This could happen if the line/col mapping is off
        otherError = "Position not recognized as macro: " & e.msg
      else:
        otherError = e.msg

    if nimsuggestUnsupported:
      skip()
    elif otherError != "":
      # NOTE: If this fails, it may indicate that:
      # 1. The fixture file line numbers changed
      # 2. nimsuggest requires different position coordinates
      # 3. The traceExpand implementation changed
      checkpoint(otherError)
      fail()
    else:
      check gotTracePath

  test "traceExpandMacro via workspace/executeCommand on macro position":
    # Test the executeCommand path (as VSCode would call it)
    let macroFile = "projects/macrotest/macrotest.nim"
    let executeParams = %*{
      "command": "nim/traceExpandMacro",
      "arguments": [{"uri": fixtureUri(macroFile), "line": 6, "character": 0}],
    }
    var gotTracePath = false
    var nimsuggestUnsupported = false
    var otherError = ""
    try:
      let res = waitFor client.call("workspace/executeCommand", executeParams)
      if res.kind == JObject and res.hasKey("tracePath"):
        let tracePath = res["tracePath"].getStr
        check tracePath.endsWith(".ct")
        check tracePath.len > 3
        gotTracePath = true
      elif res.kind == JNull:
        otherError = "Got null response"
      else:
        otherError = "Unexpected response: " & $res
    except CatchableError as e:
      if "traceExpand" in e.msg or "not support" in e.msg:
        nimsuggestUnsupported = true
      elif "No trace result" in e.msg or "not a macro" in e.msg:
        otherError = "Position not recognized as macro: " & e.msg
      else:
        otherError = e.msg

    if nimsuggestUnsupported:
      skip()
    elif otherError != "":
      checkpoint(otherError)
      fail()
    else:
      check gotTracePath
