## Stability: rapid hover on all files after all are open.
## Expected outcome: PASS (assertions only check server stays alive).

import tbughelpers
import unittest2

suite "Stability — rapid hover across all files, maxNs=2":
  let (cmdParams, ls, client) = startCombinedServer(2)

  test "18 hover requests across 7 files return valid JSON":
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
