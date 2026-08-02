## tbugs.nim — tests that document known bugs (expected to fail until fixed)
##
## Bug 1: redirect aliases from "kill and replace" inflate ls.projectFiles.len
##   past maxNimsuggestProcesses, permanently blocking new spawns.
##   Diagnosed from error_trace31.txt (melody_container_layouts.nim never cleaned up).
##
## Bug 2: warnIfUnknown cross-project guard silently returns when the intended
##   project already has a running nimsuggest, leaving the requesting file
##   permanently served by the wrong nimsuggest (the one it doesn't belong to).
##   Diagnosed from error_trace31.txt (instrument_midi_keyboard_ui.nim stuck on
##   wrong project).
##
## Both suites are run on a single combined server covering both test projects.
## Stability suites (same server) are expected to pass — they only assert the
## server stays alive, not correctness of responses.

import fixhelpers
import std/[os, strutils, sequtils, json, options]
import chronos
import unittest2

# ---------------------------------------------------------------------------
# Combined-server helpers
# ---------------------------------------------------------------------------
#
# rootUri = test_fixes/projects, so tryRelativeTo strips that prefix.
# Regexes below are relative to that root — e.g. "simple/src/.*\\.nim" not
# "test_fixes/projects/simple/src/.*\\.nim".

proc combinedMapping(): seq[NlsNimsuggestConfig] =
  @[
    NlsNimsuggestConfig(
      fileRegex: "simple/src/.*\\.nim",
      projectFile: simpleProjectFile()
    ),
    NlsNimsuggestConfig(
      fileRegex: "monorepo/pkga/src/.*\\.nim",
      projectFile: pkgaProjectFile()
    ),
    NlsNimsuggestConfig(
      fileRegex: "monorepo/pkgb/src/.*\\.nim",
      projectFile: pkgbProjectFile()
    ),
  ]

proc startCombinedServer(maxNs: int): (CommandLineParams, LanguageServer, LspSocketClient) =
  generateSimpleNimblePaths()
  generateMonorepoNimblePaths()
  let (cmdParams, ls, client) = startServer("test_fixes/projects")
  ls.workspaceConfiguration.complete(% @[NlsConfig(
    maxNimsuggestProcesses: some maxNs,
    projectMapping: some combinedMapping()
  )])
  doInitialize(client, "test_fixes/projects")
  client.notify("initialized", newJObject())
  (cmdParams, ls, client)

# Relative paths for use with sendDidOpen / sendHover / fixtureUri
const
  simpleRel  = "test_fixes/projects/simple/src/simple.nim"
  widgetRel  = "test_fixes/projects/simple/src/widget.nim"
  orphanRel  = "test_fixes/projects/simple/src/orphan.nim"
  orphan2Rel = "test_fixes/projects/simple/src/orphan2.nim"
  pkgbRel    = "test_fixes/projects/monorepo/pkgb/src/pkgb.nim"
  pkgaRel    = "test_fixes/projects/monorepo/pkga/src/pkga.nim"
  aorphanRel = "test_fixes/projects/monorepo/pkga/src/aorphan.nim"

# ---------------------------------------------------------------------------
# Bug 1: redirect aliases inflate ls.projectFiles.len past maxNimsuggestProcesses
# ---------------------------------------------------------------------------
#
# Reproduction:
#   maxNimsuggestProcesses=1.  All three simple-project files map to simple.nim.
#
#   Step 1 — open simple.nim: createOrRestartNimsuggest("simple.nim", ...)
#             → ls.projectFiles = {"simple.nim" → Proj{file=simple.nim}}   len=1
#
#   Step 2 — open orphan.nim: orphan.nim is unimported by simple.nim.
#             warnIfUnknown fires; canSpawn=false (len=1 == max=1).
#             "Kill and replace" path: stop simple.nim's nimsuggest, spawn orphan.nim
#             standalone, create redirect alias:
#             ls.projectFiles["simple.nim"] = ls.projectFiles["orphan.nim"]
#             → ls.projectFiles = {"simple.nim" → Proj{file=orphan.nim},
#                                  "orphan.nim"  → Proj{file=orphan.nim}}  len=2
#
#   Step 3 — open orphan2.nim: orphan2.nim is also unimported.
#             warnIfUnknown fires; shouldSpawnNimsuggest() counts len=2 → false.
#             canSpawn=false.  cascade prevention check:
#             ls.projectFiles["simple.nim"].file = "orphan.nim" ≠ "simple.nim"
#             AND path ("orphan2.nim") ≠ "simple.nim" → cascade prevention fires,
#             returns early.
#             Result: orphan2.nim is permanently stuck — no nimsuggest will serve it.
#
# Expected (buggy) outcome: hover on orphan2.nim returns JNull.
# The test is marked expect_failure — it documents the bug.

suite "Bug 1 — redirect aliases inflate projectFiles.len, blocking new spawns [EXPECTED FAIL]":
  let (cmdParams, ls, client) = startCombinedServer(1)

  test "hover on orphan2.nim works after two kill-and-replace cycles":
    {.cast(noSideEffect).}:
      discard  # workaround for unittest2 expect_failure scoping

    # Open simple.nim first; wait for its nimsuggest to initialise.
    sendDidOpen(client, simpleRel)
    check waitForNsInit(client, simpleProjectFile())

    # Open orphan.nim: unimported → kill-and-replace → redirect alias created.
    # warnIfUnknown is fire-and-forget; give it a moment to run.
    sendDidOpen(client, orphanRel)
    check waitForNsInit(client, simpleOrphanFile())

    # Open orphan2.nim: should trigger another kill-and-replace, but Bug 1 means
    # ls.projectFiles.len=2 > maxNimsuggestProcesses=1, so spawn is blocked.
    sendDidOpen(client, orphan2Rel)
    waitFor sleepAsync(2000)

    # With the bug, this hover returns JNull because no nimsuggest serves orphan2.nim.
    # After the fix it should return a valid Hover object with "shout".
    let hover = sendHover(client, orphan2Rel, 7, 5)
    check hover.kind == JObject          # FAILS with bug: hover is JNull
    check hover["contents"]["value"].getStr.contains("shout")

# ---------------------------------------------------------------------------
# Bug 2: cross-project guard silently returns, file stuck on wrong nimsuggest
# ---------------------------------------------------------------------------
#
# Reproduction:
#   maxNimsuggestProcesses=2.  monorepo mapping: pkga → pkga.nim, pkgb → pkgb.nim.
#
#   Step 1 — open pkgb.nim: nimsuggest spawned for pkgb.nim. hover confirms it works.
#
#   Step 2 — open pkga.nim: nimsuggest spawned alongside (second slot free). hover
#             on pkga.nim succeeds (pkga nimsuggest).
#
#   Step 3 — open aorphan.nim (in pkga/src/): projectMapping → intendedProjectFile =
#             pkga.nim.  getProjectFile → reuse pkga.nim (limit=2, two slots used).
#             projectFile = pkga.nim, intendedProjectFile = pkga.nim.
#             warnIfUnknown(aorphan, projectFile=pkga, intendedProjectFile=pkga):
#               isKnown = false (aorphan is not imported by pkga.nim).
#               canHandleUnknown = true.
#               intendedProjectFile == projectFile → standalone path.
#               Guard: "if projectFile in ls.projectFiles and
#                          ls.projectFiles[projectFile].file == projectFile and
#                          ns.finished and not ns.failed: return"
#               pkga nimsuggest IS finished and NOT failed → guard fires → return early.
#             Result: aorphan.nim is served by pkga nimsuggest, which doesn't know it.
#             Hover returns JNull because pkga nimsuggest returns length=0 for aorphan.
#
# Expected (buggy) outcome: hover on aorphan.nim returns JNull.
# The test is marked expect_failure — it documents the bug.

suite "Bug 2 — cross-project guard skips restart, file stuck on wrong nimsuggest [EXPECTED FAIL]":
  let (cmdParams, ls, client) = startCombinedServer(2)

  test "hover on aorphan.nim works after pkgb and pkga nimsuggest both running":
    # Open pkgb, confirm nimsuggest, do hover to set lastCmdDate.
    sendDidOpen(client, pkgbRel)
    check waitForNsInit(client, pkgbProjectFile())
    let hoverPkgb = sendHover(client, pkgbRel, 5, 5)
    check hoverPkgb.kind == JObject

    waitFor sleepAsync(100)

    # Open pkga, confirm nimsuggest (now 2 slots used), hover to confirm.
    sendDidOpen(client, pkgaRel)
    check waitForNsInit(client, pkgaProjectFile())
    let hoverPkga = sendHover(client, pkgaRel, 5, 5)
    check hoverPkga.kind == JObject

    # Open aorphan.nim: in pkga/src/ → intendedProject=pkga.nim → standalone path →
    # guard fires (pkga nimsuggest running) → returns early → no standalone spawn.
    sendDidOpen(client, aorphanRel)
    waitFor sleepAsync(2000)

    # With the bug, pkga nimsuggest doesn't know aorphan → returns JNull.
    # After the fix, a standalone nimsuggest should be spawned (or the spawn-alongside
    # path taken for slot 3, or the guard updated to allow standalone restart).
    let hover = sendHover(client, aorphanRel, 9, 5)
    check hover.kind == JObject          # FAILS with bug: hover is JNull
    check hover["contents"]["value"].getStr.contains("orphanColor")

# ---------------------------------------------------------------------------
# Stability sweep — all 7 files, combined server, maxNs=2 (EXPECTED PASS)
# ---------------------------------------------------------------------------
#
# These suites do NOT assert correctness of responses — only that the server
# stays alive and returns valid JSON (JNull is fine; a crash or exception is not).
# They are expected to PASS even with the bugs above, because the bugs cause
# silent failures (JNull), not server crashes.

suite "Stability — sequential open + hover of all 7 files, maxNs=2":
  let (cmdParams, ls, client) = startCombinedServer(2)

  test "open simple.nim and hover":
    sendDidOpen(client, simpleRel)
    check waitForNsInit(client, simpleProjectFile())
    let h = sendHover(client, simpleRel, 4, 5)
    check h.kind in {JNull, JObject}

  test "open widget.nim and hover":
    sendDidOpen(client, widgetRel)
    waitFor sleepAsync(500)
    let h = sendHover(client, widgetRel, 7, 5)
    check h.kind in {JNull, JObject}

  test "open orphan.nim and hover":
    sendDidOpen(client, orphanRel)
    waitFor sleepAsync(2000)
    let h = sendHover(client, orphanRel, 7, 5)
    check h.kind in {JNull, JObject}

  test "open pkgb.nim and hover":
    sendDidOpen(client, pkgbRel)
    check waitForNsInit(client, pkgbProjectFile())
    let h = sendHover(client, pkgbRel, 5, 5)
    check h.kind in {JNull, JObject}

  test "open pkga.nim and hover":
    sendDidOpen(client, pkgaRel)
    check waitForNsInit(client, pkgaProjectFile())
    let h = sendHover(client, pkgaRel, 5, 5)
    check h.kind in {JNull, JObject}

  test "open aorphan.nim and hover":
    sendDidOpen(client, aorphanRel)
    waitFor sleepAsync(2000)
    let h = sendHover(client, aorphanRel, 9, 5)
    check h.kind in {JNull, JObject}

  test "open orphan2.nim and hover":
    sendDidOpen(client, orphan2Rel)
    waitFor sleepAsync(2000)
    let h = sendHover(client, orphan2Rel, 7, 5)
    check h.kind in {JNull, JObject}

  test "server still responds after all opens":
    # A documentSymbol call on simple.nim verifies the server is not crashed.
    let uri = fixtureUri(simpleRel)
    let result = waitFor client.call(
      "textDocument/documentSymbol",
      %* {"textDocument": {"uri": uri}}
    )
    check result.kind in {JNull, JArray}

suite "Stability — interleaved open/close/reopen across all 7 files, maxNs=2":
  let (cmdParams, ls, client) = startCombinedServer(2)

  test "server survives open-close-reopen of simple.nim":
    sendDidOpen(client, simpleRel)
    check waitForNsInit(client, simpleProjectFile())
    client.notify("textDocument/didClose",
      %* {"textDocument": {"uri": fixtureUri(simpleRel)}})
    waitFor sleepAsync(200)
    sendDidOpen(client, simpleRel)
    waitFor sleepAsync(1000)
    let h = sendHover(client, simpleRel, 4, 5)
    check h.kind in {JNull, JObject}

  test "server survives rapid open of pkgb then pkga":
    sendDidOpen(client, pkgbRel)
    sendDidOpen(client, pkgaRel)
    check waitForNsInit(client, pkgbProjectFile())
    check waitForNsInit(client, pkgaProjectFile())
    let hb = sendHover(client, pkgbRel, 5, 5)
    let ha = sendHover(client, pkgaRel, 5, 5)
    check hb.kind in {JNull, JObject}
    check ha.kind in {JNull, JObject}

  test "server survives open of all 7 files without waiting for init":
    sendDidOpen(client, simpleRel)
    sendDidOpen(client, widgetRel)
    sendDidOpen(client, orphanRel)
    sendDidOpen(client, orphan2Rel)
    sendDidOpen(client, pkgbRel)
    sendDidOpen(client, pkgaRel)
    sendDidOpen(client, aorphanRel)
    waitFor sleepAsync(3000)
    # Just verify the server is alive.
    let uri = fixtureUri(pkgbRel)
    let result = waitFor client.call(
      "textDocument/documentSymbol",
      %* {"textDocument": {"uri": uri}}
    )
    check result.kind in {JNull, JArray}

suite "Stability — rapid hover on all files after all open, maxNs=2":
  let (cmdParams, ls, client) = startCombinedServer(2)

  test "18 hover requests across 7 files return valid JSON":
    # Open everything and let the nimsuggest instances settle.
    sendDidOpen(client, simpleRel)
    sendDidOpen(client, pkgbRel)
    check waitForNsInit(client, simpleProjectFile())
    check waitForNsInit(client, pkgbProjectFile())
    sendDidOpen(client, widgetRel)
    sendDidOpen(client, orphanRel)
    sendDidOpen(client, orphan2Rel)
    sendDidOpen(client, pkgaRel)
    sendDidOpen(client, aorphanRel)
    waitFor sleepAsync(3000)

    # Fire 18 hover requests and check each is well-formed JSON.
    let positions = [
      (simpleRel,  4, 5), (simpleRel,  8, 5),
      (widgetRel,  3, 5), (widgetRel,  7, 5),
      (orphanRel,  3, 5), (orphanRel,  7, 5),
      (orphan2Rel, 3, 5), (orphan2Rel, 7, 5),
      (pkgbRel,    3, 5), (pkgbRel,    5, 5),
      (pkgaRel,    3, 5), (pkgaRel,    5, 5),
      (aorphanRel, 5, 5), (aorphanRel, 9, 5),
      (simpleRel,  4, 5), (pkgbRel,    5, 5),
      (widgetRel,  7, 5), (pkgaRel,    5, 5),
    ]
    for (rel, line, col) in positions:
      let h = sendHover(client, rel, line, col)
      check h.kind in {JNull, JObject}

  test "documentSymbol on pkga and simple returns array or null":
    let uriPkga   = fixtureUri(pkgaRel)
    let uriSimple = fixtureUri(simpleRel)
    let rPkga   = waitFor client.call("textDocument/documentSymbol",
      %* {"textDocument": {"uri": uriPkga}})
    let rSimple = waitFor client.call("textDocument/documentSymbol",
      %* {"textDocument": {"uri": uriSimple}})
    check rPkga.kind   in {JNull, JArray}
    check rSimple.kind in {JNull, JArray}
