import
  std/[options, os, tables, json],
  chronos,
  chronos/asyncproc,
  unittest2,
  ../[nimlangserver, ls, lstransports2, utils],
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
  ls.setWorkspaceConfiguration(% @[NlsConfig()])

  let
    helloWorldFile = "projects/hw/hw.nim"
    helloWorldPath = fixturePath(helloWorldFile)

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "didOpenFile writes the stash file before it suspends":
    removeFile(ls.pathStorageLocation(helloWorldPath).string)

    let opened = ls.didOpenFixture(helloWorldFile)
    check fileExists(ls.pathStorageLocation(helloWorldPath).string)
    check ls.openFiles[helloWorldPath].fingerTable.len > 0

    check waitFor opened.withTimeout(30.seconds)

  test "Concurrent creations for the same project are deduplicated":
    let first = ls.createOrRestartNimsuggest(helloWorldPath, helloWorldPath)
    let second = ls.createOrRestartNimsuggest(helloWorldPath, helloWorldPath)
    check ls.nimsuggestCreations.len == 1

    waitFor allFutures(first, second).wait(30.seconds)
    check ls.nimsuggestCreations.len == 0
    check ls.projectFiles.len == 1
    check not ls.projectFiles[helloWorldPath].process.isNil

  test "Cancelling one create leaves the creation for the others":
    let
      first = ls.createOrRestartNimsuggest(helloWorldPath, helloWorldPath)
      second = ls.createOrRestartNimsuggest(helloWorldPath, helloWorldPath)
    check ls.nimsuggestCreations.len == 1

    waitFor first.cancelAndWait()
    check first.cancelled

    check waitFor second.withTimeout(30.seconds)
    check not second.cancelled
    check ls.nimsuggestCreations.len == 0
    check ls.projectFiles.len == 1
    check not ls.projectFiles[helloWorldPath].process.isNil

  test "A client that leaves with a request pending ends the session":
    let pending = ls.call("workspace/configuration", JsonString"{}")
    check not pending.isNil
    waitFor client.transport.shutdownWait()
    waitFor client.transport.closeWait()
    check waitFor ls.serve().withTimeout(30.seconds)
    # the request to the client that left fails rather than waiting forever
    check waitFor pending.withTimeout(30.seconds)
    check pending.failed

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
  ls.setWorkspaceConfiguration(% @[NlsConfig()])

  let
    helloWorldFile = "projects/hw/hw.nim"
    helloWorldPath = fixturePath(helloWorldFile)

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

  test "stopping the replaced instance is not handled as a crash":
    check waitFor ls.didOpenFixture(helloWorldFile).withTimeout(30.seconds)
    check (waitFor ls.tryGetNimsuggest(helloWorldPath).wait(30.seconds)).isSome
    let old = ls.projectFiles[helloWorldPath]
    let errors = ls.projectErrors.len

    check waitFor ls
      .createOrRestartNimsuggest(helloWorldPath, helloWorldPath)
      .withTimeout(30.seconds)
    let replacement = ls.projectFiles[helloWorldPath]
    check replacement != old
    check old.process.running() == AsyncProcessResult[bool].ok(false)
    check not old.failed
    check ls.projectErrors.len == errors
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
    helloWorldPath = fixturePath(helloWorldFile)
    saveParams = DidSaveTextDocumentParams(
      textDocument: TextDocumentIdentifier(uri: helloWorldUri)
    )
    Diagnostics = "textDocument/publishDiagnostics"

  suiteTeardown:
    waitFor ls.shutdownNimsuggest()

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
    check waitFor ls.didOpenFixture(helloWorldFile).withTimeout(30.seconds)
    check (waitFor ls.tryGetNimsuggest(helloWorldPath).wait(30.seconds)).isSome
    let ns = ls.projectFiles[helloWorldPath].ns

    # hw.nim has an error in it, so any project check publishes for it. That
    # notification is the only externally visible trace a save leaves.
    proc isForHelloWorld(json: JsonNode): bool {.gcsafe, raises: [CatchableError].} =
      {.cast(gcsafe).}:
        json{"uri"}.getStr == $helloWorldUri

    check waitFor client.waitForNotification(Diagnostics, isForHelloWorld)

    # Control: with the file open, saving runs a check. Without this the race
    # case below could pass because nothing ever publishes.
    var published = settle()
    check waitFor lspRoutes.didSave(ls, saveParams).withTimeout(30.seconds)
    check waitUntil(client.calls[Diagnostics].len > published, timeout = 30.seconds)

    # Park the handler where it waits in real life. A file with no serving
    # nimsuggest yet makes getNimsuggestInner await its projectFile, and
    # awaiting an already-resolved future does not yield, so without this the
    # whole of didSave would run synchronously and there would be no window.
    discard settle()
    let fut =
      Future[Path].Raising([CancelledError, OSError, RegexError]).init("closed race")
    ls.openFiles[helloWorldPath].projectFile = fut
    ls.openFiles[helloWorldPath].nimsuggestProject = Path("")

    let saving = lspRoutes.didSave(ls, saveParams)
    check not saving.finished

    # The editor closes the file while the save is still waiting. The save
    # has not looked the file up yet, so it will find it already closed.
    ls.openFiles.del(helloWorldPath)
    check helloWorldPath notin ls.openFiles

    # With the entry gone, the save must still tell nimsuggest to re-read the
    # file, which really was written to disk.
    ns.successfullCall = false
    fut.complete(helloWorldPath)
    check waitFor saving.withTimeout(30.seconds)
    check waitUntil(ns.successfullCall, timeout = 30.seconds)

  test "didClose for a file that was never open is a no-op":
    let unknownPath = fixturePath("projects/hw/never-opened.nim")
    check unknownPath notin ls.openFiles
    # Reaching the next line is the assertion: reading `changed` off the missing
    # entry used to dereference nil.
    check waitFor ls.didCloseFile(unknownPath).withTimeout(30.seconds)
    check unknownPath notin ls.openFiles

suite "Shutting down twice":
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
    helloWorldPath = fixturePath(helloWorldFile)

  test "a second shutdown waits for the first one to stop nimsuggest":
    # exit can arrive while shutdown is still stopping nimsuggest. If the
    # second call returned early the server would quit with it still running.
    check waitFor ls.didOpenFixture(helloWorldFile).withTimeout(30.seconds)
    check (waitFor ls.tryGetNimsuggest(helloWorldPath).wait(30.seconds)).isSome

    let first = ls.shutdownNimsuggest()
    let second = ls.shutdownNimsuggest()
    check not first.finished
    check waitFor second.withTimeout(30.seconds)
    check first.finished
