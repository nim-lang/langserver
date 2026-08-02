## Stability: interleaved open/close/reopen across all 7 files.
## Expected outcome: PASS (assertions only check server stays alive).

import tbughelpers
import unittest2

suite "Stability — interleaved open/close/reopen, maxNs=2":
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

  test "server survives rapid open of all 7 files":
    sendDidOpen(client, simpleRel)
    sendDidOpen(client, widgetRel)
    sendDidOpen(client, orphanRel)
    sendDidOpen(client, orphan2Rel)
    sendDidOpen(client, pkgbRel)
    sendDidOpen(client, pkgaRel)
    sendDidOpen(client, aorphanRel)
    waitFor sleepAsync(3000)
    let uri = fixtureUri(pkgbRel)
    let result = waitFor client.call(
      "textDocument/documentSymbol",
      %* {"textDocument": {"uri": uri}}
    )
    check result.kind in {JNull, JArray}
