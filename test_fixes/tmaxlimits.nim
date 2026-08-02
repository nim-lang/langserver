## Regression tests for fixes from the fix/maxnimsuggestlimits-clean branch.
##
## Commits covered here (not already in tmonorepo.nim):
##   2416ab6 — changed() called in checkFile before chkFile
##             (nimsuggest sees unsaved edits; diagnostics fire without save)
##   347314d — maxNimsuggestProcesses enforced at the getProjectFile mapping path
##   83f0386 — sentinel Project inserted before first await in createOrRestartNimsuggest
##             (prevents concurrent didOpen handlers from over-spawning)
##   e0fbf2b — Fix #8: config-first init; server waits for workspaceConfiguration
##             before spawning nimsuggest so projectMapping is used on first open
##
## Commits covered IMPLICITLY by tmonorepo.nim:
##   f3ac669 — Fix #7: workspace/didRenameFiles  (suite "Fix #7 and #11")
##   1cc34d0 — Fix #10: nimble.paths forwarding  (suite "Fix #10")
##   1719746 — nimble dump runs in project workingDir (tested indirectly: all suites
##             that use generateSimpleNimblePaths rely on a correct dump)
##   d6f1e03 — removes nimsuggestInit await (cleanup; implicitly tested by all suites)

import fixhelpers
import std/[os, strutils, sequtils, json, options]
import chronos
import unittest2

# ---------------------------------------------------------------------------
# Suite 1: changed() sent before chkFile (fix 2416ab6)
# ---------------------------------------------------------------------------
#
# Before this fix, checkFile only sent `chkFile` — nimsuggest's internal AST
# was never refreshed after a didChange, so diagnostics always reflected the
# last SAVED state.  After the fix, checkFile calls `changed(stashFile)` first,
# which points nimsuggest at the live editor buffer, then `chkFile` returns
# errors for the current content.
#
# The regression: open a file, send didChange with a semantic error, wait for
# the debounce (FILE_CHECK_DELAY = 1000 ms), and verify that a non-empty
# publishDiagnostics notification arrives — WITHOUT ever sending didSave.
# Without the fix the notification would contain an empty diagnostics list
# (nimsuggest returned no errors because it was still looking at the clean file).

suite "Fix — checkFile sends changed() before chkFile":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("test_fixes/projects/simple")
  ls.workspaceConfiguration.complete(% @[NlsConfig(
    maxNimsuggestProcesses: some 1,
    projectMapping: some @[
      NlsNimsuggestConfig(
        fileRegex: "test_fixes/projects/simple/src/.*\\.nim",
        projectFile: simpleProjectFile()
      )
    ]
  )])
  doInitialize(client, "test_fixes/projects/simple")
  client.notify("initialized", newJObject())

  test "publishDiagnostics fires with errors after didChange, without didSave":
    # Open simple.nim so nimsuggest starts and widget.nim enters its graph.
    sendDidOpen(client, "test_fixes/projects/simple/src/simple.nim")
    check waitForNsInit(client, simpleProjectFile())

    # Also register widget.nim as open so the server tracks it.
    sendDidOpen(client, "test_fixes/projects/simple/src/widget.nim")
    waitFor sleepAsync(200)

    # Replace widget.nim content with a version that has an undeclared identifier.
    # This is a SEMANTIC error (not syntax), so nimsuggest handles it without crashing.
    const brokenWidget =
      "## Widget module with deliberate error.\n" &
      "type Widget* = object\n" &
      "  x*, y*: int\n" &
      "\n" &
      "proc area*(w: Widget): int =\n" &
      "  undeclaredIdentifierXyzzy\n" &  # semantic error
      "\n" &
      "proc perimeter*(w: Widget): int =\n" &
      "  2 * (w.x + w.y)\n"

    sendDidChange(client, "test_fixes/projects/simple/src/widget.nim", 2, brokenWidget)

    # Wait for the checkFile debounce (1000 ms) plus nimsuggest processing.
    # waitForNotification polls every 100 ms and times out at 10 s total —
    # ample headroom even on a slow machine.
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
# Suite 2: Fix #8 — config-first init; projectMapping applied on first open
# ---------------------------------------------------------------------------
#
# Before fix #8, initNimsuggestInstances and getProjectFile ran with whatever
# configuration was present when the initialized handler fired — potentially
# before VS Code had replied to workspace/configuration.  The fix adds
# waitForWorkspaceConfiguration(), which polls ls.workspaceConfiguration until
# it is fulfilled or 30 s elapses.
#
# The regression observable from the outside: if a projectMapping is configured,
# the very first textDocument/didOpen must route to the MAPPED project file, not
# treat the opened file as its own project.  Without config-first, the mapping
# would be missing at spawn time and widget.nim would become its own project.

suite "Fix #8 — config-first init: projectMapping applied on first open":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("test_fixes/projects/simple")
  # Complete configuration BEFORE sending initialized. The server's
  # waitForWorkspaceConfiguration() finds it immediately.  The assertion below
  # verifies that the mapping WAS applied — which only happens when the config
  # is actually consulted before spawning.
  ls.workspaceConfiguration.complete(% @[NlsConfig(
    maxNimsuggestProcesses: some 1,
    projectMapping: some @[
      NlsNimsuggestConfig(
        fileRegex: "test_fixes/projects/simple/src/.*\\.nim",
        projectFile: simpleProjectFile()
      )
    ]
  )])
  doInitialize(client, "test_fixes/projects/simple")
  client.notify("initialized", newJObject())

  test "opening widget.nim (non-entry) routes to simple.nim via projectMapping":
    # widget.nim is not the nimble entry point; projectMapping maps every *.nim
    # under src/ to simple.nim.  The server must use the mapping, so nimsuggest
    # inits for simple.nim, not widget.nim.
    sendDidOpen(client, "test_fixes/projects/simple/src/widget.nim")
    check waitForNsInit(client, simpleProjectFile())

  test "no Nimsuggest initialized message mentions widget.nim as a project root":
    # If config-first failed and the mapping was ignored, the server would have
    # used widget.nim as its own project root and sent an init message for it.
    check not waitFor client.waitForNotification(
      "window/showMessage",
      proc(j: JsonNode): bool =
        let msg = j["message"].getStr("")
        "Nimsuggest initialized for" in msg and "widget.nim" in msg,
      1000
    )

# ---------------------------------------------------------------------------
# Suite 3: concurrent spawn limit (fixes 347314d + 83f0386)
# ---------------------------------------------------------------------------
#
# 347314d: shouldSpawnNimsuggest() was not called at the projectMapping path in
#   getProjectFile, so every file that matched a mapping would spawn its own
#   nimsuggest regardless of maxNimsuggestProcesses.
#
# 83f0386: shouldSpawnNimsuggest counted ls.getLspStatus().nimsuggestInstances.len
#   which only counted FINISHED instances.  Concurrent didOpen handlers all saw
#   count=0 before any nimsuggest completed, so all of them spawned.  Fix: count
#   ls.projectFiles.len (includes pending sentinels) and insert the sentinel
#   synchronously before the first await.
#
# Test: with maxNimsuggestProcesses=1 and two mapped projects, opening files for
# both in rapid succession must result in exactly one running nimsuggest, not two.
# (The second file is served by the first nimsuggest via reuse/redirect.)

suite "Fix — concurrent didOpen respects maxNimsuggestProcesses=1":
  generateMonorepoNimblePaths()
  let (cmdParams, ls, client) = startServer("test_fixes/projects/monorepo")
  ls.workspaceConfiguration.complete(% @[NlsConfig(
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
  )])
  doInitialize(client, "test_fixes/projects/monorepo")
  client.notify("initialized", newJObject())

  test "at most one nimsuggest runs when two mapped files are opened before any init":
    # Fire both opens without waiting for any response.  Before fixes 347314d and
    # 83f0386, both handlers would see an empty projectFiles table and each spawn
    # their own nimsuggest, violating the limit.
    sendDidOpen(client, "test_fixes/projects/monorepo/pkga/src/pkga.nim")
    sendDidOpen(client, "test_fixes/projects/monorepo/pkgb/src/pkgb.nim")

    # Wait for the first nimsuggest to initialise (whichever wins).
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

    # Brief grace period: if a second spawn was racing, give it time to complete
    # so the assertion isn't a false pass caught too early.
    waitFor sleepAsync(1000)

    # Status must show exactly 1 instance.
    check waitForInstanceCount(client, 1, 5000)
