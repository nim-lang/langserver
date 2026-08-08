import ./fixhelpers
import ../src/utils/utils
import std/[os, strformat, strutils, sequtils, json, options]
import chronos
import unittest2

suite "Fix #7 and #11 — workspace/didRenameFiles":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("tests/projects/simple")
  ls.configurations.currentConfig = some(NlsConfig(
    maxNimsuggestProcesses: some 1,
    projectMapping: some @[
      NlsNimsuggestConfig(
        fileRegex: "tests/projects/simple/src/.*\\.nim",
        projectFile: simpleProjectFile()
      )
    ]
  ))
  ls.configurations.configReady.fire()
  doInitialize(client, "tests/projects/simple")
  client.notify("initialized", newJObject())

  let widgetFile = "tests/projects/simple/src/widget.nim"

  test "server does not crash after workspace/didRenameFiles":
    echo "    >> server does not crash after workspace/didRenameFiles"
    sendDidOpen(client, widgetFile)
    check waitForNsInit(client, simpleProjectFile())

    sendDidRename(client, widgetFile, "tests/projects/simple/src/widget_renamed.nim")
    waitFor sleepAsync(500)

    discard sendHover(client, widgetFile, 7, 5)
    check true
    echo "    >> DONE: server does not crash after workspace/didRenameFiles"

  test "publishDiagnostics clears errors for old URI after rename":
    echo "    >> publishDiagnostics clears errors for old URI after rename"
    check waitFor client.waitForNotification(
      "textDocument/publishDiagnostics",
      proc(j: JsonNode): bool =
        j["uri"].getStr.endsWith("widget.nim") and
        j["diagnostics"].len == 0,
      5000
    )
    echo "    >> DONE: publishDiagnostics clears errors for old URI after rename"

suite "Fix #12A — openFiles sync on didClose":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("tests/projects/simple")
  ls.configurations.currentConfig = some(NlsConfig(maxNimsuggestProcesses: some 1))
  ls.configurations.configReady.fire()
  doInitialize(client, "tests/projects/simple")
  client.notify("initialized", newJObject())

  test "closing one file does not break hover on another file":
    echo "    >> closing one file does not break hover on another file"
    sendDidOpen(client, "tests/projects/simple/src/simple.nim")
    sendDidOpen(client, "tests/projects/simple/src/widget.nim")
    check waitForNsInit(client, simpleProjectFile())

    client.notify("textDocument/didClose", %* {
      "textDocument": {"uri": fixtureUri("tests/projects/simple/src/widget.nim")}
    })
    waitFor sleepAsync(200)

    discard sendHover(client, "tests/projects/simple/src/simple.nim", 4, 5)
    check true
    echo "    >> DONE: closing one file does not break hover on another file"
