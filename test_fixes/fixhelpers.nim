import std/[os, strutils, times, options, json, tables, sequtils, sugar]
import ../[nimlangserver, ls, lstransports, utils]
import ../protocol/types
import ../tests/lspsocketclient  # import without alias so we can selectively re-export
import chronos
import unittest2

# Re-export everything we need EXCEPT fixtureUri and createDidOpenParams, which we override.
export LspSocketClient, NotificationRpc, Rpc
export newLspSocketClient, notify, call, connect
export waitForNotification, waitForNotificationMessage
export registerNotification, positionParams, initialize, notificationHandle

export ls, lstransports, utils, nimlangserver, types, options, json, tables,
  sequtils, times, os, strutils, chronos

# fixtureUri that resolves from repo root, NOT tests/ (overrides lspsocketclient version)
proc fixtureUri*(path: string): string =
  pathToUri(getCurrentDir() / path)

# Override createDidOpenParams to read from repo root
proc createDidOpenParams*(file: string): DidOpenTextDocumentParams =
  DidOpenTextDocumentParams %* {
    "textDocument": {
      "uri": fixtureUri(file),
      "languageId": "nim",
      "version": 0,
      "text": readFile(getCurrentDir() / file),
    }
  }

proc generateSimpleNimblePaths*() =
  let dir = absolutePath("test_fixes" / "projects" / "simple")
  writeFile(dir / "nimble.paths", "--noNimblePath\n")

proc generateMonorepoNimblePaths*() =
  let dir = absolutePath("test_fixes" / "projects" / "monorepo")
  let pkgbSrc = dir / "pkgb" / "src"
  writeFile(
    dir / "nimble.paths",
    "--noNimblePath\n--path:\"" & pkgbSrc & "\"\n"
  )

proc startServer*(rootRelPath: string): (CommandLineParams, LanguageServer, LspSocketClient) =
  let cmdParams = CommandLineParams(
    mode: some lsp,
    transport: some socket,
    port: getNextFreePort()
  )
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )
  (cmdParams, ls, client)

proc doInitialize*(client: LspSocketClient, rootRelPath: string) =
  let initParams = LspInitializeParams %* {
    "processId": %getCurrentProcessId(),
    "rootUri": fixtureUri(rootRelPath),
    "capabilities": {
      "window": {"workDoneProgress": true},
      "workspace": {"configuration": true}
    }
  }
  discard waitFor client.initialize(initParams)

proc waitForNsInit*(client: LspSocketClient, absProjectFile: string): bool =
  waitFor client.waitForNotificationMessage(
    "Nimsuggest initialized for " & absProjectFile
  )

proc waitForInstanceCount*(client: LspSocketClient, n: int, timeoutMs = 30000): bool =
  waitFor client.waitForNotification(
    "extension/statusUpdate",
    proc(j: JsonNode): bool =
      let ports = j["nimsuggestInstances"].elems.mapIt(it["port"].getInt)
      ports.deduplicate.len == n,
    0
  )

proc sendDidOpen*(client: LspSocketClient, relPath: string) =
  client.notify("textDocument/didOpen", %createDidOpenParams(relPath))

proc sendHover*(client: LspSocketClient, relPath: string, line, col: int): JsonNode =
  let uri = fixtureUri(relPath)
  waitFor client.call("textDocument/hover", %positionParams(uri, line, col))

proc sendCompletion*(client: LspSocketClient, relPath: string, line, col: int): JsonNode =
  let uri = fixtureUri(relPath)
  let params = CompletionParams %* {
    "position": {"line": line, "character": col},
    "textDocument": {"uri": uri}
  }
  waitFor client.call("textDocument/completion", %params)

proc sendDidChange*(client: LspSocketClient, relPath: string, version: int, newText: string) =
  let uri = fixtureUri(relPath)
  client.notify("textDocument/didChange", %* {
    "textDocument": {"uri": uri, "version": version},
    "contentChanges": [{"text": newText}]
  })

proc sendDidSave*(client: LspSocketClient, relPath: string, text: string) =
  let uri = fixtureUri(relPath)
  client.notify("textDocument/didSave", %* {
    "textDocument": {"uri": uri},
    "text": text
  })

proc sendDidRename*(client: LspSocketClient, oldRelPath, newRelPath: string) =
  let oldUri = fixtureUri(oldRelPath)
  let newUri = fixtureUri(newRelPath)
  client.notify("workspace/didRenameFiles", %* {
    "files": [{"oldUri": oldUri, "newUri": newUri}]
  })

proc simpleProjectFile*(): string =
  absolutePath("test_fixes" / "projects" / "simple" / "src" / "simple.nim")

proc simpleOrphanFile*(): string =
  absolutePath("test_fixes" / "projects" / "simple" / "src" / "orphan.nim")

proc simpleOrphan2File*(): string =
  absolutePath("test_fixes" / "projects" / "simple" / "src" / "orphan2.nim")

proc pkgaProjectFile*(): string =
  absolutePath("test_fixes" / "projects" / "monorepo" / "pkga" / "src" / "pkga.nim")

proc pkgbProjectFile*(): string =
  absolutePath("test_fixes" / "projects" / "monorepo" / "pkgb" / "src" / "pkgb.nim")

proc pkgaOrphanFile*(): string =
  absolutePath("test_fixes" / "projects" / "monorepo" / "pkga" / "src" / "aorphan.nim")
