## tmaxlimits.nim — rewrite-compatible port of test_fixes/tmaxlimits.nim
##
## Covers:
##   - checkFile sends changed() before chkFile (diagnostics fire without didSave)
##   - Fix #8: config-first init (projectMapping applied on first didOpen)
##   - Concurrent didOpen respects maxNimsuggestProcesses=1
##
## Infrastructure: imports test_fixes/fixhelpers directly (already uses new src/ APIs).

import ./fixhelpers
import std/[os, strutils, sequtils, json, options]
import chronos
import unittest2

# ---------------------------------------------------------------------------
# Suite 1: changed() sent before chkFile
# ---------------------------------------------------------------------------
#
# Before this fix, checkFile only sent `chkFile` — nimsuggest's internal AST
# was never refreshed after a didChange, so diagnostics always reflected the
# last saved state. After the fix, checkFile calls `changed(stashFile)` first,
# then `chkFile` returns errors for the current content.
#
# The test: open a file, send didChange with a semantic error, wait for the
# debounce (FILE_CHECK_DELAY = 1000 ms), and verify a non-empty
# publishDiagnostics arrives WITHOUT ever sending didSave.

suite "Fix — checkFile sends changed() before chkFile":
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

  test "publishDiagnostics fires with errors after didChange, without didSave":
    echo "    >> publishDiagnostics fires with errors after didChange, without didSave"
    sendDidOpen(client, "tests/projects/simple/src/simple.nim")
    check waitForNsInit(client, simpleProjectFile())

    sendDidOpen(client, "tests/projects/simple/src/widget.nim")
    waitFor sleepAsync(200)

    const brokenWidget =
      "## Widget module with deliberate error.\n" &
      "type Widget* = object\n" &
      "  x*, y*: int\n" &
      "\n" &
      "proc area*(w: Widget): int =\n" &
      "  undeclaredIdentifierXyzzy\n" &
      "\n" &
      "proc perimeter*(w: Widget): int =\n" &
      "  2 * (w.x + w.y)\n"

    sendDidChange(client, "tests/projects/simple/src/widget.nim", 2, brokenWidget)

    check waitFor client.waitForNotification(
      "textDocument/publishDiagnostics",
      proc(j: JsonNode): bool =
        j["uri"].getStr("").contains("widget.nim") and
        j.hasKey("diagnostics") and
        j["diagnostics"].kind == JArray and
        j["diagnostics"].len > 0,
      0
    )

# ---------------------------------------------------------------------------
# Suite 2: Fix #8 — config-first init
# ---------------------------------------------------------------------------
#
# Before fix #8, getProjectFile ran before workspaceConfiguration arrived, so
# projectMapping was empty at spawn time. The fix polls until config is ready.
#
# Observable regression: the first textDocument/didOpen must route to the
# MAPPED project file, not treat the opened file as its own project.

suite "Fix #8 — config-first init: projectMapping applied on first open":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("tests/projects/simple")
  # Complete configuration BEFORE sending initialized so the server's
  # waitForWorkspaceConfiguration() finds it immediately.
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

  test "opening widget.nim (non-entry) routes to simple.nim via projectMapping":
    echo "    >> opening widget.nim (non-entry) routes to simple.nim via projectMapping"
    sendDidOpen(client, "tests/projects/simple/src/widget.nim")
    check waitForNsInit(client, simpleProjectFile())

  test "no Nimsuggest initialized message mentions widget.nim as a project root":
    echo "    >> no Nimsuggest initialized message mentions widget.nim as a project root"
    check not waitFor client.waitForNotification(
      "window/showMessage",
      proc(j: JsonNode): bool =
        let msg = j["message"].getStr("")
        "Nimsuggest initialized for" in msg and "widget.nim" in msg,
      1000
    )

# ---------------------------------------------------------------------------
# Suite 3: concurrent spawn limit
# ---------------------------------------------------------------------------
#
# With maxNimsuggestProcesses=1 and two mapped projects, opening files for both
# in rapid succession must result in exactly one running nimsuggest.

suite "Fix — concurrent didOpen respects maxNimsuggestProcesses=1":
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

  test "at most one nimsuggest runs when two mapped files are opened before any init":
    echo "    >> at most one nimsuggest runs when two mapped files are opened before any init"
    sendDidOpen(client, "tests/projects/monorepo/pkga/src/pkga.nim")
    sendDidOpen(client, "tests/projects/monorepo/pkgb/src/pkgb.nim")

    let gotPkga = pkgaProjectFile()
    let gotPkgb = pkgbProjectFile()
    check waitFor client.waitForNotification(
      "window/showMessage",
      proc(j: JsonNode): bool =
        let msg = j["message"].getStr("")
        ("Nimsuggest initialized for " & gotPkga) in msg or
        ("Nimsuggest initialized for " & gotPkgb) in msg,
      0
    )

    waitFor sleepAsync(1000)
    check waitForInstanceCount(client, 1, 5000)
