## Bug 3 regression: "assume known when busy" — one-way door, no retry.
##
## When a file's didOpen arrives while nimsuggest is busy processing a prior
## checkFile, warnIfUnknown calls isKnown with a 500ms timeout. nimsuggest
## doesn't respond in time; the file is assumed known and no kill-and-replace
## (or standalone spawn) happens. warnIfUnknown is never retried after nimsuggest
## becomes idle, so the file is permanently served by the wrong nimsuggest.
##
## Sequence:
##   simple.nim opens → nimsuggest spawned, checkFile dispatched (busy).
##   orphan.nim opens immediately (while checkFile is running):
##     warnIfUnknown → isKnown times out → assumed known → no action.
##   After checkFile completes, nimsuggest is idle — but no retry fires.
##   orphan.nim is served by simple.nim nimsuggest, which doesn't know it → JNull.
##
## Expected outcome: FAIL (documents the bug).
## The test fails at "check hover.kind == JObject" on orphan.nim.

import tbughelpers
import unittest2

suite "Bug 3 — assume-known-when-busy: no retry after nimsuggest becomes idle":
  let (cmdParams, ls, client) = startCombinedServer(1)

  test "hover on orphan.nim works after isKnown timed out during checkFile":
    # Step 1: open simple.nim, wait for nimsuggest init.
    # checkFile for simple.nim is dispatched immediately after init.
    sendDidOpen(client, simpleRel)
    check waitForNsInit(client, simpleProjectFile())

    # Step 2: open orphan.nim immediately — nimsuggest is busy with checkFile.
    # warnIfUnknown → isKnown → 500ms timeout → assumed known → no standalone spawn.
    sendDidOpen(client, orphanRel)

    # Step 3: wait well past checkFile completion for nimsuggest to become idle.
    # No retry of warnIfUnknown fires; orphan.nim stays on wrong nimsuggest.
    waitFor sleepAsync(4000)

    let hover = sendHover(client, orphanRel, 7, 5)
    check hover.kind == JObject         # FAILS with bug (hover is JNull)
    check hover["contents"]["value"].getStr.contains("double")
