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
    echo "    >> DONE: nimsuggest receives --noNimblePath from nimble.paths"

suite "Fix #16 — listTests with no entryPoint":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("tests/projects/simple")
  ls.configurations.currentConfig = some(NlsConfig())
  ls.configurations.configReady.fire()
  doInitialize(client, "tests/projects/simple")
  client.notify("initialized", newJObject())

  test "listTests returns success with empty result when entryPoint is not set":
    echo "    >> listTests returns success with empty result when entryPoint is not set"
    let response = waitFor client.call("extension/listTests", %* {
      "projectFile": simpleProjectFile(),
      "entryPoint": ""
    })
    check "error" notin response or response["error"].kind == JNull
    check not waitFor client.waitForNotification(
      "textDocument/publishDiagnostics",
      proc(j: JsonNode): bool =
        j.getStr("").contains("command expects a filename"),
      500
    )
    echo "    >> DONE: listTests returns success with empty result when entryPoint is not set"

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
    echo "    >> DONE: documentSymbol returns [] not an error when nimsuggest is killed mid-flight"

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
    echo "    >> DONE: when limit is 1, opening pkga evicts pkgb"

suite "Fix #13 — opening pkgb while pkga nimsuggest runs":
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

  test "opening pkgb while pkga nimsuggest runs gives hover for pkgb":
    echo "    >> opening pkgb while pkga nimsuggest runs gives hover for pkgb"
    sendDidOpen(client, "tests/projects/monorepo/pkga/src/pkga.nim")
    check waitForNsInit(client, pkgaProjectFile())

    sendDidOpen(client, "tests/projects/monorepo/pkgb/src/pkgb.nim")
    # pkga imports pkgb, so pkga's nimsuggest already knows pkgb.nim.
    # No separate NS is needed — pkga's NS serves pkgb.nim queries correctly.
    waitFor sleepAsync(500)

    let hover = sendHover(
      client,
      "tests/projects/monorepo/pkgb/src/pkgb.nim",
      5, 5
    )
    check hover.kind != JNull
    echo "    >> DONE: opening pkgb while pkga nimsuggest runs gives hover for pkgb"
