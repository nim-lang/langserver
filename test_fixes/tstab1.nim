## Stability: sequential open + hover of all 7 files on one combined server.
## Expected outcome: PASS (assertions only check server stays alive).

import tbughelpers
import unittest2

suite "Stability — sequential open + hover, maxNs=2":
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

  test "server still responds (documentSymbol on simple.nim)":
    let uri = fixtureUri(simpleRel)
    let result = waitFor client.call(
      "textDocument/documentSymbol",
      %* {"textDocument": {"uri": uri}}
    )
    check result.kind in {JNull, JArray}
