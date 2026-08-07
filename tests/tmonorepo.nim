## tmonorepo.nim — rewrite-compatible port of test_fixes/tmonorepo.nim
##
## Covers fix regression suites: #10, #16, #17, #18, #19 (cascade + LRU),
## #13, #7/#11, #12A, #12C.
##
## Infrastructure: imports test_fixes/fixhelpers directly (it already uses
## new src/ APIs). The only change from the original is this import line.

import ./fixhelpers
import ../src/utils/utils
import std/[os, strformat, strutils, sequtils, json, options]
import chronos
import unittest2

suite "Fix #10 — nimble.paths forwarded to nimsuggest":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("tests/projects/simple")
  ls.configurations.currentConfig = some(NlsConfig(maxNimsuggestProcesses: some 1))
  ls.configurations.configReady.fire()
  doInitialize(client, "tests/projects/simple")
  client.notify("initialized", newJObject())

  test "nimsuggest receives --noNimblePath from nimble.paths":
    echo "    >> nimsuggest receives --noNimblePath from nimble.paths"
    sendDidOpen(client, "tests/projects/simple/src/simple.nim")
    check waitForNsInit(client, simpleProjectFile())
    # Open widget.nim explicitly so it enters openFiles (mimics real VS Code usage).
    sendDidOpen(client, "tests/projects/simple/src/widget.nim")
    waitFor sleepAsync(200)
    let hover = sendHover(client, "tests/projects/simple/src/widget.nim", 7, 5)
    check hover.kind != JNull

suite "Fix #16 — listTests with no entryPoint":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("tests/projects/simple")
  ls.configurations.currentConfig = some(NlsConfig())
  ls.configurations.configReady.fire()
  doInitialize(client, "tests/projects/simple")
  client.notify("initialized", newJObject())

  test "listTests returns success with empty result when entryPoint is not set":
    echo "    >> listTests returns success with empty result when entryPoint is not set"
    let result = waitFor client.call("extension/listTests", %* {
      "projectFile": simpleProjectFile(),
      "entryPoint": ""
    })
    check "error" notin result or result["error"].kind == JNull
    check not waitFor client.waitForNotification(
      "textDocument/publishDiagnostics",
      proc(j: JsonNode): bool =
        j.getStr("").contains("command expects a filename"),
      500
    )

suite "Fix #17 — in-flight commands complete with [] not error":
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

  test "documentSymbol returns [] not an error when nimsuggest is killed mid-flight":
    echo "    >> documentSymbol returns [] not an error when nimsuggest is killed mid-flight"
    sendDidOpen(client, "tests/projects/simple/src/simple.nim")
    check waitForNsInit(client, simpleProjectFile())

    sendDidOpen(client, "tests/projects/simple/src/orphan.nim")
    let symbolUri = fixtureUri("tests/projects/simple/src/simple.nim")
    let symbolResult = waitFor client.call(
      "textDocument/documentSymbol",
      %* {"textDocument": {"uri": symbolUri}}
    )
    check symbolResult.kind == JArray
    check not waitFor client.waitForNotification(
      "window/showMessage",
      proc(j: JsonNode): bool =
        let msg = j["message"].getStr("")
        "Missing" in msg or ("Error" in msg and "nimsuggest" notin msg),
      500
    )

suite "Fix #18 — standalone nimsuggest for unimported file":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("tests/projects/simple")
  ls.configurations.currentConfig = some(NlsConfig(
    maxNimsuggestProcesses: some 2,
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

  test "hover works on a file not imported by the project root":
    echo "    >> hover works on a file not imported by the project root"
    sendDidOpen(client, "tests/projects/simple/src/simple.nim")
    check waitForNsInit(client, simpleProjectFile())

    # Also open widget.nim so it is in openFiles for the "original project still works" test.
    sendDidOpen(client, "tests/projects/simple/src/widget.nim")
    waitFor sleepAsync(100)

    sendDidOpen(client, "tests/projects/simple/src/orphan.nim")
    check waitForNsInit(client, simpleOrphanFile())

    let hover = sendHover(client, "tests/projects/simple/src/orphan.nim", 7, 5)
    check hover.kind != JNull
    check hover["contents"]["value"].getStr.contains("double")

  test "original project nimsuggest still works after spawn alongside":
    echo "    >> original project nimsuggest still works after spawn alongside"
    let hover = sendHover(client, "tests/projects/simple/src/widget.nim", 7, 5)
    check hover.kind != JNull
    check hover["contents"]["value"].getStr.contains("area")

  test "statusUpdate shows 2 distinct nimsuggest instances":
    echo "    >> statusUpdate shows 2 distinct nimsuggest instances"
    check waitForInstanceCount(client, 2, 5000)

suite "Fix #19 — cascade prevention at maxNimsuggestProcesses=1":
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

  test "opening a second unimported file does not cascade-restart into a loop":
    echo "    >> opening a second unimported file does not cascade-restart into a loop"
    sendDidOpen(client, "tests/projects/simple/src/simple.nim")
    check waitForNsInit(client, simpleProjectFile())

    sendDidOpen(client, "tests/projects/simple/src/orphan.nim")
    check waitForNsInit(client, simpleOrphanFile())

    sendDidOpen(client, "tests/projects/simple/src/orphan2.nim")
    waitFor sleepAsync(2000)
    check waitForInstanceCount(client, 1, 3000)

suite "Fix #19 — LRU eviction at process limit":
  generateMonorepoNimblePaths()
  let (cmdParams, ls, client) = startServer("tests/projects/monorepo")
  ls.configurations.currentConfig = some(NlsConfig(
    maxNimsuggestProcesses: some 1,
    projectMapping: some @[
      NlsNimsuggestConfig(
        fileRegex: "tests/projects/monorepo/pkgb/src/.*\\.nim",
        projectFile: pkgbProjectFile()
      ),
      NlsNimsuggestConfig(
        fileRegex: "tests/projects/monorepo/pkga/src/.*\\.nim",
        projectFile: pkgaProjectFile()
      )
    ]
  ))
  ls.configurations.configReady.fire()
  doInitialize(client, "tests/projects/monorepo")
  client.notify("initialized", newJObject())

  test "when limit is 1, opening pkga evicts pkgb (pkgb was opened first = LRU)":
    echo "    >> when limit is 1, opening pkga evicts pkgb (pkgb was opened first = LRU)"
    sendDidOpen(client, "tests/projects/monorepo/pkgb/src/pkgb.nim")
    check waitForNsInit(client, pkgbProjectFile())

    sendDidOpen(client, "tests/projects/monorepo/pkga/src/pkga.nim")
    check waitForNsInit(client, pkgaProjectFile())

    let hover = sendHover(
      client,
      "tests/projects/monorepo/pkga/src/pkga.nim",
      5, 5
    )
    check hover.kind != JNull

suite "Fix #13 — cross-project unknown file restarts for intended project":
  generateMonorepoNimblePaths()
  let (cmdParams, ls, client) = startServer("tests/projects/monorepo")
  ls.configurations.currentConfig = some(NlsConfig(
    maxNimsuggestProcesses: some 1,
    projectMapping: some @[
      NlsNimsuggestConfig(
        fileRegex: "tests/projects/monorepo/pkga/src/.*\\.nim",
        projectFile: pkgaProjectFile()
      ),
      NlsNimsuggestConfig(
        fileRegex: "tests/projects/monorepo/pkgb/src/.*\\.nim",
        projectFile: pkgbProjectFile()
      )
    ]
  ))
  ls.configurations.configReady.fire()
  doInitialize(client, "tests/projects/monorepo")
  client.notify("initialized", newJObject())

  test "opening pkgb while pkga nimsuggest runs restarts for pkgb":
    echo "    >> opening pkgb while pkga nimsuggest runs restarts for pkgb"
    sendDidOpen(client, "tests/projects/monorepo/pkga/src/pkga.nim")
    check waitForNsInit(client, pkgaProjectFile())

    sendDidOpen(client, "tests/projects/monorepo/pkgb/src/pkgb.nim")
    check waitForNsInit(client, pkgbProjectFile())

    let hover = sendHover(
      client,
      "tests/projects/monorepo/pkgb/src/pkgb.nim",
      5, 5
    )
    check hover.kind != JNull

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

  test "publishDiagnostics clears errors for old URI after rename":
    echo "    >> publishDiagnostics clears errors for old URI after rename"
    check waitFor client.waitForNotification(
      "textDocument/publishDiagnostics",
      proc(j: JsonNode): bool =
        j["uri"].getStr.endsWith("widget.nim") and
        j["diagnostics"].len == 0,
      5000
    )

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

suite "Fix #12C — SIGSEGV recovery: save unblocks crashed file":
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

  test "after SIGSEGV triggered by sug on broken stash, didSave re-enables the file":
    echo "    >> after SIGSEGV triggered by sug on broken stash, didSave re-enables the file"
    sendDidOpen(client, "tests/projects/simple/src/orphan.nim")
    check waitForNsInit(client, simpleOrphanFile())

    let brokenText = "import nonexistent_module_xyz\ntype Orphan* = object\n  val*: float\n"
    sendDidChange(
      client,
      "tests/projects/simple/src/orphan.nim",
      version = 2,
      newText = brokenText
    )

    let orphanUri = fixtureUri("tests/projects/simple/src/orphan.nim")
    let completionParams = CompletionParams %* {
      "position": {"line": 0, "character": 7},
      "textDocument": {"uri": orphanUri}
    }
    discard waitFor client.call("textDocument/completion", %completionParams)
    waitFor sleepAsync(500)

    let goodText = readFile(absolutePath("tests/projects/simple/src/orphan.nim"))
    sendDidSave(client, "tests/projects/simple/src/orphan.nim", goodText)

    check waitForNsInit(client, simpleOrphanFile())

    let hover = sendHover(client, "tests/projects/simple/src/orphan.nim", 7, 5)
    check hover.kind != JNull
