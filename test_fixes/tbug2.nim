## Bug 2 regression: warnIfUnknown cross-project guard silently returns when
## the intended project already has a running nimsuggest, leaving the file
## permanently served by the wrong nimsuggest.
##
## NOTE: maxNimsuggestProcesses always reads as 1 in tests (the server sends a
## workspace/configuration request that the test client never answers, so the
## config reverts to the default of 1). startCombinedServer(1) is used explicitly.
##
## Sequence with maxNs=1:
##   pkgb opens → nimsuggest for pkgb (1 slot).
##   pkga opens → intendedProjectFile=pkga ≠ projectFile=pkgb(reused LRU) →
##     branch 1: kill pkgb, spawn pkga, redirect alias: projectFiles[pkgb]=projectFiles[pkga],
##     nsCount=2.
##   aorphan opens → intendedProjectFile=pkga, shouldSpawn: nsCount=2 > max=1 →
##     canSpawn=false → reuse LRU.
##     * If LRU=pkgb: intendedProjectFile=pkga ≠ projectFile=pkgb → branch 1:
##       guard fires (pkga already running) → return early.
##     * If LRU=pkga: intendedProjectFile=pkga = projectFile=pkga → standalone path:
##       guard fires (pkga running, file==path) → return early.
##   Either way, aorphan is served by pkga nimsuggest which doesn't know it → JNull.
##
## Expected outcome: FAIL (documents the bug).
## The test fails at "check hover.kind == JObject" on aorphan.nim.

import tbughelpers
import unittest2

suite "Bug 2 — cross-project guard skips restart, file stuck on wrong nimsuggest":
  let (cmdParams, ls, client) = startCombinedServer(1)

  test "hover on aorphan.nim works after pkgb and pkga nimsuggest initialised":
    # Step 1: open pkgb, wait for init, let checkFile settle.
    sendDidOpen(client, pkgbRel)
    check waitForNsInit(client, pkgbProjectFile())
    waitFor sleepAsync(1500)

    # Step 2: open pkga — mapped to pkga.nim, but reused LRU=pkgb (nsCount=1 max=1).
    # warnIfUnknown branch 1: kill pkgb, spawn pkga, create redirect alias.
    # After: projectFiles = {pkgb → redirect→pkga, pkga → pkga} len=2.
    sendDidOpen(client, pkgaRel)
    check waitForNsInit(client, pkgaProjectFile())
    waitFor sleepAsync(1500)

    # Step 3: open aorphan.nim — nsCount=2 > max=1.
    # warnIfUnknown guard fires (pkga already running, intendedProjectFile=pkga).
    # aorphan.nim is served by pkga nimsuggest which doesn't know it → JNull.
    sendDidOpen(client, aorphanRel)
    waitFor sleepAsync(2000)

    let hover = sendHover(client, aorphanRel, 9, 5)
    check hover.kind == JObject         # FAILS with bug (hover is JNull)
    check hover["contents"]["value"].getStr.contains("orphanColor")
