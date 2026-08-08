import ./fixhelpers
import ../src/utils/utils
import std/[os, strformat, strutils, sequtils, json, options]
import chronos
import unittest2

suite "Fix #19 — cascade prevention at maxNimsuggestProcesses=1":
  generateSimpleNimblePaths()
  let (cmdParams, ls, client) = startServer("tests/projects/simple")
  ls.configurations.currentConfig = some(NlsConfig(
    maxNimsuggestProcesses: some 1,
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

  test "opening a second unimported file does not cascade-restart into a loop":
    echo "    >> opening a second unimported file does not cascade-restart into a loop"
    sendDidOpen(client, "tests/projects/simple/src/simple.nim")
    check waitForNsInit(client, simpleProjectFile())

    sendDidOpen(client, "tests/projects/simple/src/orphan.nim")
    check waitForNsInit(client, simpleOrphanFile())

    sendDidOpen(client, "tests/projects/simple/src/orphan2.nim")
    waitFor sleepAsync(2000)
    check waitForInstanceCount(client, 1, 3000)
    echo "    >> DONE: opening a second unimported file does not cascade-restart into a loop"
