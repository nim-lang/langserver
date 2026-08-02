## Shared helpers for tbugs* test files.

import fixhelpers
import std/[os, json, options]
import chronos
export fixhelpers, os, json, options, chronos

# rootUri = test_fixes/projects, so tryRelativeTo strips that prefix.
# Regexes are relative to that root.
proc combinedMapping*(): seq[NlsNimsuggestConfig] =
  @[
    NlsNimsuggestConfig(
      fileRegex: "simple/src/.*\\.nim",
      projectFile: simpleProjectFile()
    ),
    NlsNimsuggestConfig(
      fileRegex: "monorepo/pkga/src/.*\\.nim",
      projectFile: pkgaProjectFile()
    ),
    NlsNimsuggestConfig(
      fileRegex: "monorepo/pkgb/src/.*\\.nim",
      projectFile: pkgbProjectFile()
    ),
  ]

proc startCombinedServer*(maxNs: int): (CommandLineParams, LanguageServer, LspSocketClient) =
  generateSimpleNimblePaths()
  generateMonorepoNimblePaths()
  let (cmdParams, ls, client) = startServer("test_fixes/projects")
  doInitialize(client, "test_fixes/projects")
  client.notify("initialized", newJObject())
  # The initialized handler calls maybeRequestConfigurationFromClient, which
  # replaces ls.workspaceConfiguration with a new pending future from
  # ls.call("workspace/configuration"). The test client never answers that call.
  # Give the handler time to fire, then complete the new future ourselves.
  waitFor sleepAsync(200)
  if not ls.workspaceConfiguration.finished:
    ls.workspaceConfiguration.complete(% @[NlsConfig(
      maxNimsuggestProcesses: some maxNs,
      projectMapping: some combinedMapping()
    )])
  (cmdParams, ls, client)

const
  simpleRel*  = "test_fixes/projects/simple/src/simple.nim"
  widgetRel*  = "test_fixes/projects/simple/src/widget.nim"
  orphanRel*  = "test_fixes/projects/simple/src/orphan.nim"
  orphan2Rel* = "test_fixes/projects/simple/src/orphan2.nim"
  pkgbRel*    = "test_fixes/projects/monorepo/pkgb/src/pkgb.nim"
  pkgaRel*    = "test_fixes/projects/monorepo/pkga/src/pkga.nim"
  aorphanRel* = "test_fixes/projects/monorepo/pkga/src/aorphan.nim"
