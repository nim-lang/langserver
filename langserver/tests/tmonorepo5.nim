import ./fixhelpers
import ../src/utils/utils
import std/[os, strformat, strutils, sequtils, json, options]
import chronos
import unittest2

suite "Fix #18 — standalone nimsuggest for unimported file":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("tests/projects/simple")
  ls.configurations.currentConfig = some(NlsConfig(
    maxNimsuggestProcesses: some 2,
    projectMapping: some @[
      NlsNimsuggestConfig(
        fileRegex: "tests/projects/simple/src/.*\\.nim",
        projectFile: simpleProjectFile()
      )
    ]
  ))
  ls.configurations.configReady.fire()
  doInitialize(client, "tests/projects/simple")
  client.notify("initialized", newJObject())

  test "hover works on a file not imported by the project root":
    echo "    >> hover works on a file not imported by the project root"
    sendDidOpen(client, "tests/projects/simple/src/simple.nim")
    check waitForNsInit(client, simpleProjectFile())

    # Also open widget.nim so it is in openFiles for the "original project still works" test.
    sendDidOpen(client, "tests/projects/simple/src/widget.nim")
    waitFor sleepAsync(100)

    sendDidOpen(client, "tests/projects/simple/src/orphan.nim")
    check waitForNsInit(client, simpleOrphanFile())

    let hover = sendHover(client, "tests/projects/simple/src/orphan.nim", 7, 5)
    check hover.kind != JNull
    check hover["contents"]["value"].getStr.contains("double")
    echo "    >> DONE: hover works on a file not imported by the project root"

  test "original project nimsuggest still works after spawn alongside":
    echo "    >> original project nimsuggest still works after spawn alongside"
    let hover = sendHover(client, "tests/projects/simple/src/widget.nim", 7, 5)
    check hover.kind != JNull
    check hover["contents"]["value"].getStr.contains("area")
    echo "    >> DONE: original project nimsuggest still works after spawn alongside"

  test "statusUpdate shows 2 distinct nimsuggest instances":
    echo "    >> statusUpdate shows 2 distinct nimsuggest instances"
    check waitForInstanceCount(client, 2, 5000)
    echo "    >> DONE: statusUpdate shows 2 distinct nimsuggest instances"
