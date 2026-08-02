## Bug 1 regression: redirect aliases from "kill and replace" inflate
## ls.projectFiles.len past maxNimsuggestProcesses, permanently blocking spawns.
##
## Root cause: after kill-and-replace for orphan.nim:
##   ls.projectFiles = {"simple.nim" → redirect→orphan, "orphan.nim" → orphan}  len=2
## When orphan2.nim opens, shouldSpawnNimsuggest sees len=2 > max=1.
## The cascade prevention check then fires (redirect alias detected, path ≠ projectFile)
## and returns early — no nimsuggest ever serves orphan2.nim.
##
## NOTE: a 1.5s delay is added after simple.nim init to let checkFile complete
## before opening orphan.nim. Without this delay the 500ms isKnown timeout fires
## (nimsuggest busy with checkFile), orphan.nim is assumed-known, no kill-and-replace
## happens, and Bug 1 can't be reached.
##
## Expected outcome: FAIL (documents the bug).
## The test fails at "check hover.kind == JObject" on orphan2.nim.

import tbughelpers
import unittest2

suite "Bug 1 — redirect aliases inflate projectFiles.len, blocking new spawns":
  let (cmdParams, ls, client) = startCombinedServer(1)

  test "hover on orphan2.nim works after two kill-and-replace cycles":
    # Step 1: open simple.nim — nimsuggest spawned, 1 slot used.
    sendDidOpen(client, simpleRel)
    check waitForNsInit(client, simpleProjectFile())

    # Wait for checkFile to complete so isKnown doesn't time out on the next open.
    waitFor sleepAsync(1500)

    # Step 2: open orphan.nim — unimported by simple.nim.
    # isKnown(orphan.nim) → false. warnIfUnknown: kill simple, spawn orphan standalone.
    # After: ls.projectFiles = {simple.nim → redirect→orphan, orphan.nim → orphan} len=2.
    sendDidOpen(client, orphanRel)
    check waitForNsInit(client, simpleOrphanFile())

    # Wait for checkFile on orphan.nim to settle.
    waitFor sleepAsync(1500)

    # Step 3: open orphan2.nim — unimported too.
    # shouldSpawnNimsuggest: nsCount=2 > max=1 → canSpawn=false → kill-and-replace path.
    # cascade prevention: projectFiles["simple.nim"].file = "orphan.nim" ≠ "simple.nim"
    #   AND path("orphan2.nim") ≠ "simple.nim" → fires → return early.
    # Result: no nimsuggest ever serves orphan2.nim.
    sendDidOpen(client, orphan2Rel)
    waitFor sleepAsync(2000)

    let hover = sendHover(client, orphan2Rel, 7, 5)
    check hover.kind == JObject         # FAILS with bug (hover is JNull)
    check hover["contents"]["value"].getStr.contains("shout")
