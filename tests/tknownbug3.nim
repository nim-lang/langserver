## tknownbug3.nim — Documents Known Bug 3: assume-known-when-busy, no retry.
##
## EXPECTED TO FAIL. Excluded from all.nim. Run manually to confirm the bug
## still exists or to verify a fix:
##
##   nim c --path:. -r tests_rewrite/tknownbug3.nim
##
## Bug description:
##   When textDocument/didOpen arrives while nimsuggest is busy processing
##   checkFile for a prior file, the CHECK_KNOWN command calls isKnownProc
##   which has a 500ms timeout. Nimsuggest is busy (TCP queue occupied), so
##   the isKnown call times out and returns true (assumed known). No standalone
##   spawn fires. There is no retry mechanism — CHECK_KNOWN is only sent once,
##   at didOpen time. The file is permanently unserved by any nimsuggest that
##   actually knows it. Hover returns JNull.
##
##   Root cause is in execCheckKnown (src/langserver/queues.nim): when isKnown
##   times out the function logs a warning and returns without triggering any
##   spawn. A retry mechanism or a post-idle re-check would fix this.
##
## This bug exists in both the old ls.nim architecture and the new dp-rewrite
## architecture. It is documented here so that a fix can be verified by making
## this test pass.

import ./tbughelpers
import unittest2

suite "Known Bug 3 — assume-known-when-busy: no retry [EXPECTED FAIL]":
  # maxNs=1 ensures the orphan.nim didOpen arrives while simple's checkFile
  # is still occupying the nimsuggest TCP socket.
  let (cmdParams, ls, client) = startCombinedServer(1)

  test "hover on orphan.nim works after isKnown timed out during checkFile":
    # Step 1: open simple.nim — nimsuggest starts and checkFile is dispatched.
    sendDidOpen(client, simpleRel)
    check waitForNsInit(client, simpleProjectFile())

    # Step 2: open orphan.nim IMMEDIATELY — checkFile for simple.nim is still
    # running. isKnown times out (500ms), file is assumed known, no spawn fires.
    sendDidOpen(client, orphanRel)

    # Step 3: wait well past checkFile completion (no retry fires after idle).
    waitFor sleepAsync(4000)

    # Step 4: hover should return content — FAILS because orphan.nim is
    # unserved (assumed-known, no nimsuggest knows it).
    let hover = sendHover(client, orphanRel, 7, 5)
    check hover.kind == JObject       # FAILS: returns JNull
    check hover["contents"]["value"].getStr.contains("double")
