import
  std/[options, os, tables, json],
  chronos,
  unittest2,
  ../[nimlangserver, ls, utils],
  ../suggestapi,
  ../protocol/types,
  ./[lspsocketclient, testhelpers]

# `lsp` alone would shadow the ServerMode.lsp enum value.
import ../routes/lsp as lspRoutes

suite "Async safety":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )

  let initParams =
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities":
        {"window": {"workDoneProgress": false}, "workspace": {"configuration": true}},
    }
  discard waitFor client.initialize(initParams)

  let
    helloWorldFile = "projects/hw/hw.nim"
    helloWorldUri = fixtureUri(helloWorldFile)
    helloWorldPath = uriToPath(helloWorldUri)

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "didOpenFile writes the stash file before it suspends":
    removeFile(ls.uriStorageLocation(helloWorldUri))
    let textDocument = TextDocumentItem(
      uri: helloWorldUri,
      languageId: "nim",
      version: 0,
      text: readFile("tests" / helloWorldFile),
    )

    let opened = ls.didOpenFile(textDocument)
    check fileExists(ls.uriStorageLocation(helloWorldUri))
    check ls.openFiles[helloWorldUri].fingerTable.len > 0

    check waitFor opened.withTimeout(30.seconds)

  test "Concurrent creations for the same project are deduplicated":
    let first = ls.createOrRestartNimsuggest(helloWorldPath, helloWorldUri)
    let second = ls.createOrRestartNimsuggest(helloWorldPath, helloWorldUri)
    check ls.nimsuggestCreations.len == 1

    waitFor allFutures(first, second).wait(30.seconds)
    check ls.nimsuggestCreations.len == 0
    check ls.projectFiles.len == 1
    check not ls.projectFiles[helloWorldPath].process.isNil

  test "Cancelling one create leaves the creation for the others":
    let
      first = ls.createOrRestartNimsuggest(helloWorldPath, helloWorldUri)
      second = ls.createOrRestartNimsuggest(helloWorldPath, helloWorldUri)
    check ls.nimsuggestCreations.len == 1

    waitFor first.cancelAndWait()
    check first.cancelled

    check waitFor second.withTimeout(30.seconds)
    check not second.cancelled
    check ls.nimsuggestCreations.len == 0
    check ls.projectFiles.len == 1
    check not ls.projectFiles[helloWorldPath].process.isNil

  test "The server survives a client that leaves with a request pending":
    let leaving = newLspSocketClient()
    waitFor leaving.connect("localhost", cmdParams.port)
    let pending = ls.call("workspace/configuration", newJNull())
    check not pending.isNil
    waitFor leaving.transport.closeWait()
    waitFor sleepAsync(500.milliseconds)

    let revived = newLspSocketClient()
    waitFor revived.connect("localhost", cmdParams.port)
    let res = waitFor revived.call("shutdown", newJNull()).wait(30.seconds)
    check res.kind == JNull

suite "Replacing a running nimsuggest":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )
  discard waitFor client.initialize(
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities":
        {"window": {"workDoneProgress": false}, "workspace": {"configuration": true}},
    }
  )

  let
    helloWorldFile = "projects/hw/hw.nim"
    helloWorldUri = fixtureUri(helloWorldFile)
    helloWorldPath = uriToPath(helloWorldUri)

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "stopping the replaced instance is not handled as a crash":
    let textDocument = TextDocumentItem(
      uri: helloWorldUri,
      languageId: "nim",
      version: 0,
      text: readFile("tests" / helloWorldFile),
    )
    check waitFor ls.didOpenFile(textDocument).withTimeout(30.seconds)
    let old = ls.projectFiles[helloWorldPath]
    let oldNs = old.ns
    # Having served a request is what made the error path auto-restart it.
    check waitUntil(oldNs.successfullCall, timeout = 30.seconds)

    check waitFor ls
      .createOrRestartNimsuggest(helloWorldPath, helloWorldUri)
      .withTimeout(30.seconds)
    let replacement = ls.projectFiles[helloWorldPath]
    check replacement != old

    # Wait for the old process to be gone and its stderr closing handled, then
    # give anything that triggers time to run.
    check waitUntil(old.failed, timeout = 30.seconds)
    waitFor sleepAsync(2.seconds)

    check ls.failTable.getOrDefault(helloWorldPath, 0) == 0
    check ls.nimsuggestCreations.len == 0
    check ls.projectFiles[helloWorldPath] == replacement
    check not replacement.failed

suite "Documents closed while a handler is suspended":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )
  discard waitFor client.initialize(
    LspInitializeParams %* {
      "processId": %getCurrentProcessId(),
      "rootUri": fixtureUri("projects/hw/"),
      "capabilities":
        {"window": {"workDoneProgress": false}, "workspace": {"configuration": true}},
    }
  )
  ls.setWorkspaceConfiguration(% @[NlsConfig()])

  let
    helloWorldFile = "projects/hw/hw.nim"
    helloWorldUri = fixtureUri(helloWorldFile)
    helloWorldPath = uriToPath(helloWorldUri)
    saveParams = DidSaveTextDocumentParams(
      textDocument: TextDocumentIdentifier(uri: helloWorldUri)
    )
    Diagnostics = "textDocument/publishDiagnostics"

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  proc settle(): int =
    ## A check that runs while another is in progress re-arms itself
    ## (needsCheckProject), so wait until diagnostics stop arriving before
    ## attributing the next one to the save under test. Returns the count.
    var
      count = client.calls[Diagnostics].len
      quietSince = Moment.now()

    proc isQuiet(): bool =
      if count != client.calls[Diagnostics].len:
        count = client.calls[Diagnostics].len
        quietSince = Moment.now()
      Moment.now() - quietSince > 2.seconds

    check waitUntil(isQuiet(), timeout = 30.seconds)
    count

  test "didSave checks the project even if the file closes while it waits":
    let textDocument = TextDocumentItem(
      uri: helloWorldUri,
      languageId: "nim",
      version: 0,
      text: readFile("tests" / helloWorldFile),
    )
    check waitFor ls.didOpenFile(textDocument).withTimeout(30.seconds)
    let ns = ls.projectFiles[helloWorldPath].ns

    # hw.nim has an error in it, so any project check publishes for it. That
    # notification is the only externally visible trace a save leaves.
    proc isForHelloWorld(json: JsonNode): bool {.gcsafe, raises: [CatchableError].} =
      {.cast(gcsafe).}:
        json{"uri"}.getStr == helloWorldUri

    check waitFor client.waitForNotification(Diagnostics, isForHelloWorld)

    # Control: with the file open, saving runs a check. Without this the race
    # case below could pass because nothing ever publishes.
    var published = settle()
    check waitFor lspRoutes.didSave(ls, saveParams).withTimeout(30.seconds)
    check waitUntil(client.calls[Diagnostics].len > published, timeout = 30.seconds)

    # Park the handler where it waits in real life. getNimsuggestInner awaits
    # the file's projectFile, and awaiting an already-resolved future does not
    # yield, so without this the whole of didSave would run synchronously and
    # there would be no window at all.
    discard settle()
    let fut =
      Future[string].Raising([CancelledError, OSError, RegexError]).init("closed race")
    ls.openFiles[helloWorldUri].projectFile = fut

    let saving = lspRoutes.didSave(ls, saveParams)
    check not saving.finished

    # A didClose drops the entry while the handler is parked. Its openFiles
    # lookups are still ahead of it.
    ls.openFiles.del(helloWorldUri)
    check helloWorldUri notin ls.openFiles

    # With the entry gone, checkProject bails out in its own tryGetNimsuggest,
    # so telling nimsuggest to re-read the file is the only thing left that the
    # save can still do — and the file really was written to disk.
    ns.successfullCall = false
    fut.complete(helloWorldPath)
    check waitFor saving.withTimeout(30.seconds)
    check waitUntil(ns.successfullCall, timeout = 30.seconds)

  test "didClose for a file that was never open is a no-op":
    let unknownUri = fixtureUri("projects/hw/never-opened.nim")
    check unknownUri notin ls.openFiles
    # Reaching the next line is the assertion: reading `changed` off the missing
    # entry used to dereference nil.
    check waitFor ls.didCloseFile(unknownUri).withTimeout(30.seconds)
    check unknownUri notin ls.openFiles
