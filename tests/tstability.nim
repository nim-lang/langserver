## tstability.nim — rewrite-compatible port of test_fixes/tstab1+2+3.nim
##
## Three stability suites combined:
##   1. Sequential open + hover of all 7 files (tstab1)
##   2. Interleaved open/close/reopen (tstab2)
##   3. Rapid hover across all files (tstab3)
##
## All assertions use lenient checks (JNull or JObject/JArray) — the goal is
## server survival under load, not content correctness. These tests pass
## regardless of Bug 3 (assume-known-when-busy) since hover may legitimately
## return JNull for files not yet served by a nimsuggest.
##
## Infrastructure: imports test_fixes/tbughelpers for startCombinedServer and
## 7-file path constants. That module already uses new src/ APIs.

import ../test_fixes/tbughelpers
import unittest2

suite "Stability — sequential open + hover, maxNs=2":
  let (cmdParams, ls, client) = startCombinedServer(2)

  test "open simple.nim and hover":
    echo "    >> open simple.nim and hover"
    sendDidOpen(client, simpleRel)
    check waitForNsInit(client, simpleProjectFile())
    let h = sendHover(client, simpleRel, 4, 5)
    check h.kind in {JNull, JObject}

  test "open widget.nim and hover":
    echo "    >> open widget.nim and hover"
    sendDidOpen(client, widgetRel)
    waitFor sleepAsync(500)
    let h = sendHover(client, widgetRel, 7, 5)
    check h.kind in {JNull, JObject}

  test "open orphan.nim and hover":
    echo "    >> open orphan.nim and hover"
    sendDidOpen(client, orphanRel)
    waitFor sleepAsync(2000)
    let h = sendHover(client, orphanRel, 7, 5)
    check h.kind in {JNull, JObject}

  test "open pkgb.nim and hover":
    echo "    >> open pkgb.nim and hover"
    sendDidOpen(client, pkgbRel)
    check waitForNsInit(client, pkgbProjectFile())
    let h = sendHover(client, pkgbRel, 5, 5)
    check h.kind in {JNull, JObject}

  test "open pkga.nim and hover":
    echo "    >> open pkga.nim and hover"
    sendDidOpen(client, pkgaRel)
    check waitForNsInit(client, pkgaProjectFile())
    let h = sendHover(client, pkgaRel, 5, 5)
    check h.kind in {JNull, JObject}

  test "open aorphan.nim and hover":
    echo "    >> open aorphan.nim and hover"
    sendDidOpen(client, aorphanRel)
    waitFor sleepAsync(2000)
    let h = sendHover(client, aorphanRel, 9, 5)
    check h.kind in {JNull, JObject}

  test "open orphan2.nim and hover":
    echo "    >> open orphan2.nim and hover"
    sendDidOpen(client, orphan2Rel)
    waitFor sleepAsync(2000)
    let h = sendHover(client, orphan2Rel, 7, 5)
    check h.kind in {JNull, JObject}

  test "server still responds (documentSymbol on simple.nim)":
    echo "    >> server still responds (documentSymbol on simple.nim)"
    let uri = fixtureUri(simpleRel)
    let result = waitFor client.call(
      "textDocument/documentSymbol",
      %* {"textDocument": {"uri": uri}}
    )
    check result.kind in {JNull, JArray}


suite "Stability — interleaved open/close/reopen, maxNs=2":
  let (cmdParams, ls, client) = startCombinedServer(2)

  test "server survives open-close-reopen of simple.nim":
    echo "    >> server survives open-close-reopen of simple.nim"
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
    echo "    >> server survives rapid open of pkgb then pkga"
    sendDidOpen(client, pkgbRel)
    sendDidOpen(client, pkgaRel)
    check waitForNsInit(client, pkgbProjectFile())
    check waitForNsInit(client, pkgaProjectFile())
    let hb = sendHover(client, pkgbRel, 5, 5)
    let ha = sendHover(client, pkgaRel, 5, 5)
    check hb.kind in {JNull, JObject}
    check ha.kind in {JNull, JObject}

  test "server survives rapid open of all 7 files":
    echo "    >> server survives rapid open of all 7 files"
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


suite "Stability — rapid hover across all files, maxNs=2":
  let (cmdParams, ls, client) = startCombinedServer(2)

  test "18 hover requests across 7 files return valid JSON":
    echo "    >> 18 hover requests across 7 files return valid JSON"
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
    echo "    >> documentSymbol on pkga and simple returns array or null"
    let uriPkga   = fixtureUri(pkgaRel)
    let uriSimple = fixtureUri(simpleRel)
    let rPkga   = waitFor client.call("textDocument/documentSymbol",
      %* {"textDocument": {"uri": uriPkga}})
    let rSimple = waitFor client.call("textDocument/documentSymbol",
      %* {"textDocument": {"uri": uriSimple}})
    check rPkga.kind   in {JNull, JArray}
    check rSimple.kind in {JNull, JArray}
