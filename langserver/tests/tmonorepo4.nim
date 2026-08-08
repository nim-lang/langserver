import ./fixhelpers
import ../src/utils/utils
import std/[os, strformat, strutils, sequtils, json, options]
import chronos
import unittest2

suite "Fix #12C — SIGSEGV recovery: save unblocks crashed file":
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

  test "after SIGSEGV triggered by sug on broken stash, didSave re-enables the file":
    echo "    >> after SIGSEGV triggered by sug on broken stash, didSave re-enables the file"
    sendDidOpen(client, "tests/projects/simple/src/orphan.nim")
    echo "    >> [12C] waiting for nimsuggest init..."
    check waitForNsInit(client, simpleOrphanFile())
    echo "    >> [12C] nimsuggest ready, sending broken change..."

    let brokenText = "import nonexistent_module_xyz\ntype Orphan* = object\n  val*: float\n"
    sendDidChange(
      client,
      "tests/projects/simple/src/orphan.nim",
      version = 2,
      newText = brokenText
    )

    let orphanUri = fixtureUri("tests/projects/simple/src/orphan.nim")
    let completionParams = CompletionParams %* {
      "position": {"line": 0, "character": 7},
      "textDocument": {"uri": orphanUri}
    }
    echo "    >> [12C] sending completion to trigger crash..."
    discard waitFor client.call("textDocument/completion", %completionParams)
    echo "    >> [12C] completion returned, sleeping..."
    waitFor sleepAsync(500)

    let goodText = readFile(absolutePath("tests/projects/simple/src/orphan.nim"))
    echo "    >> [12C] sending didSave with good text..."
    sendDidSave(client, "tests/projects/simple/src/orphan.nim", goodText)

    echo "    >> [12C] waiting for nimsuggest re-init after save..."
    check waitForNsInit(client, simpleOrphanFile())
    echo "    >> [12C] re-init done, sending hover..."

    let hover = sendHover(client, "tests/projects/simple/src/orphan.nim", 7, 5)
    echo "    >> [12C] hover result: ", $hover
    check hover.kind != JNull
    echo "    >> DONE: after SIGSEGV triggered by sug on broken stash, didSave re-enables the file"
