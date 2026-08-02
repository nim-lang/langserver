import fixhelpers
import std/[os, strformat, strutils, sequtils, json, options]
import chronos
import unittest2

suite "Fix #10 — nimble.paths forwarded to nimsuggest":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("test_fixes/projects/simple")
  ls.configurations.currentConfig = some(NlsConfig(maxNimsuggestProcesses: some 1))
  ls.configurations.configReady.fire()
  doInitialize(client, "test_fixes/projects/simple")
  client.notify("initialized", newJObject())

  test "nimsuggest receives --noNimblePath from nimble.paths":
    sendDidOpen(client, "test_fixes/projects/simple/src/simple.nim")
    check waitForNsInit(client, simpleProjectFile())
    # Open widget.nim explicitly so it enters openFiles (mimics real VS Code usage).
    sendDidOpen(client, "test_fixes/projects/simple/src/widget.nim")
    waitFor sleepAsync(200)
    let hover = sendHover(client, "test_fixes/projects/simple/src/widget.nim", 7, 5)
    check hover.kind != JNull

suite "Fix #16 — listTests with no entryPoint":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("test_fixes/projects/simple")
  ls.configurations.currentConfig = some(NlsConfig())
  ls.configurations.configReady.fire()
  doInitialize(client, "test_fixes/projects/simple")
  client.notify("initialized", newJObject())

  test "listTests returns success with empty result when entryPoint is not set":
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
  let (cmdParams, ls, client) = startServer("test_fixes/projects/simple")
  ls.configurations.currentConfig = some(NlsConfig(
    maxNimsuggestProcesses: some 1,
    projectMapping: some @[
      NlsNimsuggestConfig(
        fileRegex: "test_fixes/projects/simple/src/.*\\.nim",
        projectFile: simpleProjectFile()
      )
    ]
  ))
  ls.configurations.configReady.fire()
  doInitialize(client, "test_fixes/projects/simple")
  client.notify("initialized", newJObject())

  test "documentSymbol returns [] not an error when nimsuggest is killed mid-flight":
    sendDidOpen(client, "test_fixes/projects/simple/src/simple.nim")
    check waitForNsInit(client, simpleProjectFile())

    sendDidOpen(client, "test_fixes/projects/simple/src/orphan.nim")
    let symbolUri = fixtureUri("test_fixes/projects/simple/src/simple.nim")
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
  let (cmdParams, ls, client) = startServer("test_fixes/projects/simple")
  ls.configurations.currentConfig = some(NlsConfig(
    maxNimsuggestProcesses: some 2,
    projectMapping: some @[
      NlsNimsuggestConfig(
        fileRegex: "test_fixes/projects/simple/src/.*\\.nim",
        projectFile: simpleProjectFile()
      )
    ]
  ))
  ls.configurations.configReady.fire()
  doInitialize(client, "test_fixes/projects/simple")
  client.notify("initialized", newJObject())

  test "hover works on a file not imported by the project root":
    sendDidOpen(client, "test_fixes/projects/simple/src/simple.nim")
    check waitForNsInit(client, simpleProjectFile())

    sendDidOpen(client, "test_fixes/projects/simple/src/orphan.nim")
    check waitForNsInit(client, simpleOrphanFile())

    let hover = sendHover(client, "test_fixes/projects/simple/src/orphan.nim", 7, 5)
    check hover.kind != JNull
    check hover["contents"]["value"].getStr.contains("double")

  test "original project nimsuggest still works after spawn alongside":
    let hover = sendHover(client, "test_fixes/projects/simple/src/widget.nim", 7, 5)
    check hover.kind != JNull
    check hover["contents"]["value"].getStr.contains("area")

  test "statusUpdate shows 2 distinct nimsuggest instances":
    check waitForInstanceCount(client, 2, 5000)

suite "Fix #19 — cascade prevention at maxNimsuggestProcesses=1":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("test_fixes/projects/simple")
  ls.configurations.currentConfig = some(NlsConfig(
    maxNimsuggestProcesses: some 1,
    projectMapping: some @[
      NlsNimsuggestConfig(
        fileRegex: "test_fixes/projects/simple/src/.*\\.nim",
        projectFile: simpleProjectFile()
      )
    ]
  ))
  ls.configurations.configReady.fire()
  doInitialize(client, "test_fixes/projects/simple")
  client.notify("initialized", newJObject())

  test "opening a second unimported file does not cascade-restart into a loop":
    sendDidOpen(client, "test_fixes/projects/simple/src/simple.nim")
    check waitForNsInit(client, simpleProjectFile())

    sendDidOpen(client, "test_fixes/projects/simple/src/orphan.nim")
    check waitForNsInit(client, simpleOrphanFile())

    sendDidOpen(client, "test_fixes/projects/simple/src/orphan2.nim")
    waitFor sleepAsync(2000)
    check waitForInstanceCount(client, 1, 3000)

suite "Fix #19 — LRU eviction at process limit":
  generateMonorepoNimblePaths()
  let (cmdParams, ls, client) = startServer("test_fixes/projects/monorepo")
  ls.configurations.currentConfig = some(NlsConfig(
    maxNimsuggestProcesses: some 1,
    projectMapping: some @[
      NlsNimsuggestConfig(
        fileRegex: "test_fixes/projects/monorepo/pkgb/src/.*\\.nim",
        projectFile: pkgbProjectFile()
      ),
      NlsNimsuggestConfig(
        fileRegex: "test_fixes/projects/monorepo/pkga/src/.*\\.nim",
        projectFile: pkgaProjectFile()
      )
    ]
  ))
  ls.configurations.configReady.fire()
  doInitialize(client, "test_fixes/projects/monorepo")
  client.notify("initialized", newJObject())

  test "when limit is 1, opening pkga evicts pkgb (pkgb was opened first = LRU)":
    sendDidOpen(client, "test_fixes/projects/monorepo/pkgb/src/pkgb.nim")
    check waitForNsInit(client, pkgbProjectFile())

    sendDidOpen(client, "test_fixes/projects/monorepo/pkga/src/pkga.nim")
    check waitForNsInit(client, pkgaProjectFile())

    let hover = sendHover(
      client,
      "test_fixes/projects/monorepo/pkga/src/pkga.nim",
      5, 5
    )
    check hover.kind != JNull

suite "Fix #13 — cross-project unknown file restarts for intended project":
  generateMonorepoNimblePaths()
  let (cmdParams, ls, client) = startServer("test_fixes/projects/monorepo")
  ls.configurations.currentConfig = some(NlsConfig(
    maxNimsuggestProcesses: some 1,
    projectMapping: some @[
      NlsNimsuggestConfig(
        fileRegex: "test_fixes/projects/monorepo/pkga/src/.*\\.nim",
        projectFile: pkgaProjectFile()
      ),
      NlsNimsuggestConfig(
        fileRegex: "test_fixes/projects/monorepo/pkgb/src/.*\\.nim",
        projectFile: pkgbProjectFile()
      )
    ]
  ))
  ls.configurations.configReady.fire()
  doInitialize(client, "test_fixes/projects/monorepo")
  client.notify("initialized", newJObject())

  test "opening pkgb while pkga nimsuggest runs restarts for pkgb":
    sendDidOpen(client, "test_fixes/projects/monorepo/pkga/src/pkga.nim")
    check waitForNsInit(client, pkgaProjectFile())

    sendDidOpen(client, "test_fixes/projects/monorepo/pkgb/src/pkgb.nim")
    check waitForNsInit(client, pkgbProjectFile())

    let hover = sendHover(
      client,
      "test_fixes/projects/monorepo/pkgb/src/pkgb.nim",
      5, 5
    )
    check hover.kind != JNull

suite "Fix #7 and #11 — workspace/didRenameFiles":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("test_fixes/projects/simple")
  ls.configurations.currentConfig = some(NlsConfig(
    maxNimsuggestProcesses: some 1,
    projectMapping: some @[
      NlsNimsuggestConfig(
        fileRegex: "test_fixes/projects/simple/src/.*\\.nim",
        projectFile: simpleProjectFile()
      )
    ]
  ))
  ls.configurations.configReady.fire()
  doInitialize(client, "test_fixes/projects/simple")
  client.notify("initialized", newJObject())

  let widgetFile = "test_fixes/projects/simple/src/widget.nim"

  test "server does not crash after workspace/didRenameFiles":
    sendDidOpen(client, widgetFile)
    check waitForNsInit(client, simpleProjectFile())

    sendDidRename(client, widgetFile, "test_fixes/projects/simple/src/widget_renamed.nim")
    waitFor sleepAsync(500)

    let hover = sendHover(client, widgetFile, 7, 5)
    check true

  test "publishDiagnostics clears errors for old URI after rename":
    check waitFor client.waitForNotification(
      "textDocument/publishDiagnostics",
      proc(j: JsonNode): bool =
        j["uri"].getStr.endsWith("widget.nim") and
        j["diagnostics"].len == 0,
      5000
    )

suite "Fix #12A — openFiles sync on didClose":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("test_fixes/projects/simple")
  ls.configurations.currentConfig = some(NlsConfig(maxNimsuggestProcesses: some 1))
  ls.configurations.configReady.fire()
  doInitialize(client, "test_fixes/projects/simple")
  client.notify("initialized", newJObject())

  test "closing one file does not break hover on another file":
    sendDidOpen(client, "test_fixes/projects/simple/src/simple.nim")
    sendDidOpen(client, "test_fixes/projects/simple/src/widget.nim")
    check waitForNsInit(client, simpleProjectFile())

    client.notify("textDocument/didClose", %* {
      "textDocument": {"uri": fixtureUri("test_fixes/projects/simple/src/widget.nim")}
    })
    waitFor sleepAsync(200)

    let hover = sendHover(client, "test_fixes/projects/simple/src/simple.nim", 4, 5)
    check true

suite "Fix #12C — SIGSEGV recovery: save unblocks crashed file":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("test_fixes/projects/simple")
  ls.configurations.currentConfig = some(NlsConfig(
    maxNimsuggestProcesses: some 1,
    projectMapping: some @[
      NlsNimsuggestConfig(
        fileRegex: "test_fixes/projects/simple/src/.*\\.nim",
        projectFile: simpleProjectFile()
      )
    ]
  ))
  ls.configurations.configReady.fire()
  doInitialize(client, "test_fixes/projects/simple")
  client.notify("initialized", newJObject())

  test "after SIGSEGV triggered by sug on broken stash, didSave re-enables the file":
    sendDidOpen(client, "test_fixes/projects/simple/src/orphan.nim")
    check waitForNsInit(client, simpleOrphanFile())

    let brokenText = "import nonexistent_module_xyz\ntype Orphan* = object\n  val*: float\n"
    sendDidChange(
      client,
      "test_fixes/projects/simple/src/orphan.nim",
      version = 2,
      newText = brokenText
    )

    let orphanUri = fixtureUri("test_fixes/projects/simple/src/orphan.nim")
    let completionParams = CompletionParams %* {
      "position": {"line": 0, "character": 7},
      "textDocument": {"uri": orphanUri}
    }
    discard waitFor client.call("textDocument/completion", %completionParams)
    waitFor sleepAsync(500)

    let goodText = readFile(absolutePath("test_fixes/projects/simple/src/orphan.nim"))
    sendDidSave(client, "test_fixes/projects/simple/src/orphan.nim", goodText)

    check waitForNsInit(client, simpleOrphanFile())

    let hover = sendHover(client, "test_fixes/projects/simple/src/orphan.nim", 7, 5)
    check hover.kind != JNull
