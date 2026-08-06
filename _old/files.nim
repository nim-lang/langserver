import std/[os, options, hashes, sets, strformat, sugar, sequtils, strutils]
import chronos
import chronicles

import ../protocol/types
import ../nim_tools/nimsuggest/[nimsuggest_types, nimsuggest]
import ../nim_tools/nimcheck/nimcheck
import ../nim_tools/compiler/nim_compiler
import ./[configurations, langserver_types, constants, utils, queue_types, queues, diagnostics]
# import ../queries/requests



# === textDocument/didChange ===

# proc didChange*(
#   ls: LanguageServer, params: DidChangeTextDocumentParams
# ): Future[void] {.async.} =
#   ls.addFileAccessQueryToQueue()

# proc scheduleFileCheck(ls: LanguageServer, uri: string) {.gcsafe, raises: [].} =
#   if not ls.getWorkspaceConfiguration().autoCheckFile.get(true):
#     return
#   # schedule file check after the file is modified
#   let fileData = ls.files.openFiles.getOrDefault(uri)
#   if fileData.cancelFileCheck != nil and not fileData.cancelFileCheck.finished:
#     fileData.cancelFileCheck.complete()

#   if fileData.checkInProgress:
#     fileData.needsChecking = true
#     return

#   var cancelFuture = newFuture[void]()
#   fileData.cancelFileCheck = cancelFuture

#   sleepAsync(FILE_CHECK_DELAY).addCallback do():
#     if not cancelFuture.finished:
#       fileData.checkInProgress = true
#       ls.checkFile(uri).addCallback do() {.gcsafe, raises: [].}:
#         try:
#           ls.files.openFiles[uri].checkInProgress = false
#           if fileData.needsChecking:
#             fileData.needsChecking = false
#             ls.scheduleFileCheck(uri)
#         except KeyError:
#           discard

proc didChange*(
  ls: LanguageServer, params: DidChangeTextDocumentParams
): Future[void] {.async.} =
  with params:
    let uri = textDocument.uri
    if uri notin ls.files.openFiles:
      return
    let file = open(ls.uriStorageLocation(uri), fmWrite)

    ls.files.openFiles[uri].fingerTable = @[]
    ls.files.openFiles[uri].changed = true
    if contentChanges.len <= 0:
      file.close()
      return
    for line in contentChanges[0].text.splitLines:
      ls.files.openFiles[uri].fingerTable.add line.createUTFMapping()
      file.writeLine line
    file.close()
    # NOTE: I am going to remove this scheduled file-checking that runs after the user has not been typing for 1 second, or so, and instead just have this run on the user saving.
    # ls.scheduleFileCheck(uri)

# === textDocument/willSaveWaitUntil ===
# willSaveWaitUntil — VS Code asks the server "before I write the file to disk, do you want to make any last-minute edits?" The server can respond with a list of TextEdits (e.g. format the file), which VS Code applies before saving. VS Code waits for the response before proceeding.

# didSave — VS Code tells the server "the file has been saved to disk."

# In this codebase, willSaveWaitUntil is used to implement format-on-save: if formatOnSave is enabled and nph (the Nim formatter) is available, the server returns a formatting edit so the file gets formatted at the moment of saving, before it hits disk.


# === textDocument/willSaveWaitUntil ===
# willSaveWaitUntil — VS Code asks the server "before I write the file to disk, do you want to make any last-minute edits?" The server can respond with a list of TextEdits (e.g. format the file), which VS Code applies before saving. VS Code waits for the response before proceeding.
# didSave — VS Code tells the server "the file has been saved to disk."
# In this codebase, willSaveWaitUntil is used to implement format-on-save: if formatOnSave is enabled and nph (the Nim formatter) is available, the server returns a formatting edit so the file gets formatted at the moment of saving, before it hits disk.

proc willSaveWaitUntil*(
    ls: LanguageServer, params: WillSaveTextDocumentParams
): Future[seq[TextEdit]] {.async.} =
  debug "Received willSaveWaitUntil request"

  let
    uri = params.textDocument.uri
    config = ls.getWorkspaceConfiguration()
    nphPath = getNphPath()

  let shouldFormat =
    nphPath.isSome and ls.capabilities.lspServerCapabilities.documentFormattingProvider.get(false) and
    config.formatOnSave.get(false)

  if shouldFormat:
    debug "Formatting document before save", uri = uri
    let formatTextEdit = await ls.format(nphPath.get(), uri)
    if formatTextEdit.isSome:
      return @[formatTextEdit.get]

  return @[]

proc checkFile*(ls: LanguageServer, uri: string): Future[void] {.async.} =
  if uri notin ls.files.openFiles:
    return
  let fileInfo = ls.files.openFiles[uri]
  if fileInfo.slot == nil:
    return

  let conf = ls.getWorkspaceConfiguration()
  let useNimCheck = conf.useNimCheck.get(USE_NIM_CHECK_BY_DEFAULT)
  let nimPath = conf.getNimPath()
  let path = uriToPath(uri)

  if useNimCheck and nimPath.isSome:
    let checkResults = await nimCheck(path, nimPath.get)
    ls.sendDiagnostics(checkResults, path)
    return

  # Route through the per-slot queue. processQueries awaits slot.ns.get
  # internally, so checkFile never needs to touch the NimSuggest handle directly.
  # CHANGED is sent first (if there are unsaved edits) so nimsuggest v4 marks
  # the module dirty and picks up the stash content before CHECK_FILE runs.
  if fileInfo.changed:
    discard await ls.queryFile(uri, NimsuggestQueryKind.CHANGED)
  let results = await ls.queryFile(uri, NimsuggestQueryKind.CHECK_FILE)
  ls.sendDiagnostics(results.filter(s => s.filePath != "???"), path)

proc didCloseFile*(ls: LanguageServer, uri: string) =
  debug "Closed the following document:", uri = uri

  if uri notin ls.files.openFiles:
    return
  let fileInfo = ls.files.openFiles[uri]

  if fileInfo.changed:
    # check the file if it is closed but not saved.
    asyncSpawn ls.checkFile(uri)

  # Unassign from slot
  if fileInfo.slot != nil:
    fileInfo.slot.unassignUri(uri)

  ls.files.openFiles.del(uri)

  # Cancel any pending file check
  if fileInfo.cancelFileCheck != nil and not fileInfo.cancelFileCheck.finished:
    fileInfo.cancelFileCheck.complete()

proc makeIdleFile*(ls: LanguageServer, file: NlsFileInfo) =
  let uri = file.textDocument.uri
  if uri in ls.files.openFiles:
    ls.didCloseFile(uri)
    ls.files.idleOpenFiles[uri] = file

proc didRenameFile*(ls: LanguageServer, oldUri, newUri: string) =
  debug "File renamed", oldUri = oldUri, newUri = newUri

  # Move the stash file so any pending content checks use the right path
  let oldStash = ls.uriStorageLocation(oldUri)
  let newStash = ls.uriStorageLocation(newUri)
  if oldStash.fileExists:
    try:
      moveFile(oldStash, newStash)
    except Exception as e:
      debug "Failed to move stash file on rename",
        oldStash = oldStash, newStash = newStash, msg = e.msg

  # If a .nimble file was renamed, invalidate its dump cache entry
  let oldPath = uriToPath(oldUri)
  if oldPath.endsWith(".nimble"):
    ls.nimDumpCache.del(oldPath)
    ls.nimDumpCache.del(uriToPath(newUri))

  # If the file is currently open, migrate its entry to the new URI
  if oldUri in ls.files.openFiles:
    let fileInfo = ls.files.openFiles[oldUri]
    let slot = fileInfo.slot

    # Atomic rename in both tables (no await between)
    if slot != nil:
      slot.unassignUri(oldUri)
      slot.assignUri(newUri)
    ls.files.openFiles[newUri] = NlsFileInfo(
      slot: slot,
      changed: fileInfo.changed,
      fingerTable: fileInfo.fingerTable,
      textDocument: TextDocumentItem(
        uri: newUri,
        languageId: fileInfo.textDocument.languageId,
        version: fileInfo.textDocument.version,
        text: fileInfo.textDocument.text,
      ),
    )
    ls.files.openFiles.del(oldUri)

    # Clear diagnostics for the old URI unconditionally so the editor stops
    # showing stale errors on the now-gone path (fix #7).
    ls.sendDiagnostics(newSeq[Suggest](), oldPath)

    # Tell nimsuggest to rebuild its module graph
    if oldPath.endsWith(".nim") and slot != nil and slot.isLive:
      slot.send SlotCommand(kind: SlotCommandKind.RECOMPILE)

proc didDeleteFile*(ls: LanguageServer, uri: string) =
  debug "File deleted", uri = uri
  let path = uriToPath(uri)

  # If a .nimble file was deleted, invalidate its dump cache entry
  if path.endsWith(".nimble"):
    ls.nimDumpCache.del(path)

  if uri in ls.files.openFiles:
    let fileInfo = ls.files.openFiles[uri]
    if fileInfo.slot != nil:
      fileInfo.slot.unassignUri(uri)
      if path.endsWith(".nim") and fileInfo.slot.isLive:
        fileInfo.slot.send SlotCommand(kind: SlotCommandKind.RECOMPILE)
    ls.files.openFiles.del(uri)

proc didOpenFile*(
  ls: LanguageServer, doc: TextDocumentItem
): Future[void] {.async.} =
  let uri = doc.uri
  if uri in ls.files.openFiles:
    debug "didOpenFile: URI already tracked, skipping", uri = uri
    return

  # Wait for config before making routing decisions (30s polling timeout)
  await ls.waitForWorkspaceConfiguration()

  # Re-check after the await in case concurrent open beat us
  if uri in ls.files.openFiles:
    debug "didOpenFile: URI tracked after config wait (concurrent open), skipping",
      uri = uri
    return

  debug "New document opened for URI:", uri = uri

  # Find or create the slot for this URI (sync after config is ready)
  let slot = ls.getOrCreateSlotForUri(uri)

  # Write the initial stash file
  let storagePath = ls.files.storageDir / (hash(uri).toHex & ".nim")
  try:
    writeFile(storagePath, doc.text)
  except IOError as ex:
    warn "Failed to write stash file; hover/completion may show stale content",
      path = storagePath, msg = ex.msg
  except OSError as ex:
    warn "Failed to write stash file; hover/completion may show stale content",
      path = storagePath, msg = ex.msg

  # Build finger table for UTF-16 mapping
  var fingerTable: seq[seq[tuple[u16pos, offset: int]]] = @[]
  for line in doc.text.splitLines:
    fingerTable.add line.createUTFMapping()

  # Register in the file table (sync, atomic)
  let fileInfo = NlsFileInfo(
    slot: slot,
    changed: false,
    fingerTable: fingerTable,
    textDocument: doc,
  )
  ls.files.openFiles[uri] = fileInfo

  if uri in ls.files.idleOpenFiles:
    ls.files.idleOpenFiles.del(uri)

  # Register ownership in the slot (sync, atomic with above)
  slot.assignUri(uri)

  # Spawn the slot's nimsuggest if not already running.
  # ns.isNone means the slot was just created (pre-SPAWNING state) but the
  # actual spawn hasn't been sent yet — send it now.
  if not slot.isActive or slot.ns.isNone:
    slot.send SlotCommand(
      kind: SlotCommandKind.SPAWN,
      spawnProjectFile: slot.projectFile,
      spawnTriggerUri: uri,
    )

  # Ask nimsuggest whether this file is in its module graph.
  # routingPolicy in the processor will handle any needed reassignment/respawn.
  slot.send SlotCommand(
    kind: SlotCommandKind.CHECK_KNOWN,
    checkUri: uri,
    checkIntendedProjectFile: ls.getIntendedProject(uri),
  )

  debug "Opened file", uri = uri



# === textDocument/willSaveWaitUntil ===
proc willSaveWaitUntil*(
    ls: LanguageServer, params: WillSaveTextDocumentParams
): Future[seq[TextEdit]] {.async.} =
  debug "Received willSaveWaitUntil request"
  return await ls.addWillSaveQueryToQueue(params)

# === textDocument/didSave ===
proc didSave*(
  ls: LanguageServer, params: DidSaveTextDocumentParams
): Future[void] {.async.} =

  let
    uri = params.textDocument.uri
    config = ls.getWorkspaceConfiguration()

  # Un-block crash-inducing URIs on save: the user may have fixed the code.
  # In the new slot model, crashedUris lives on the slot itself.
  let path = uri.uriToPath
  debug "didSave: enter", uri = uri
  if uri in ls.files.openFiles:
    let fileInfo = ls.files.openFiles[uri]
    if fileInfo.slot != nil:
      let wasCrashed = uri in fileInfo.slot.crashedUris
      fileInfo.slot.crashedUris.excl(uri)

      debug "didSave: crashedUris unblock",
        uri = uri, wasCrashed = wasCrashed,
        slotProject = fileInfo.slot.projectFile,
        slotState = $fileInfo.slot.state,
        slotCrashCount = fileInfo.slot.crashCount
    else:
      debug "didSave: fileInfo.slot is nil!", uri = uri
  else:
    debug "didSave: uri not in openFiles", uri = uri

  if uri notin ls.files.openFiles:
    return

  ls.files.openFiles[uri].changed = false
  # Route CHANGED through the per-slot queue so it is serialized with concurrent queries.
  debug "didSave: sending CHANGED query", uri = uri
  traceAsyncErrors ls.queryFile(uri, NimsuggestQueryKind.CHANGED)

  if config.checkOnSave.get(true):
    debug "Checking project", uri = uri
    traceAsyncErrors ls.checkProject(uri)

# === textDocument/didClose ===

proc checkFile*(ls: LanguageServer, uri: string): Future[void] {.async.} =
  if uri notin ls.files.openFiles:
    return
  let fileInfo = ls.files.openFiles[uri]
  if fileInfo.slot == nil:
    return

  let conf = ls.getWorkspaceConfiguration()
  let useNimCheck = conf.useNimCheck.get(USE_NIM_CHECK_BY_DEFAULT)
  let nimPath = conf.getNimPath()
  let path = uriToPath(uri)

  if useNimCheck and nimPath.isSome:
    let checkResults = await nimCheck(path, nimPath.get)
    ls.sendDiagnostics(checkResults, path)
    return

  # Route through the per-slot queue. processQueries awaits slot.ns.get
  # internally, so checkFile never needs to touch the NimSuggest handle directly.
  # CHANGED is sent first (if there are unsaved edits) so nimsuggest v4 marks
  # the module dirty and picks up the stash content before CHECK_FILE runs.
  if fileInfo.changed:
    discard await ls.queryFile(uri, NimsuggestQueryKind.CHANGED)
  let results = await ls.queryFile(uri, NimsuggestQueryKind.CHECK_FILE)
  ls.sendDiagnostics(results.filter(s => s.filePath != "???"), path)

proc didCloseFile*(ls: LanguageServer, uri: string) =
  debug "Closed the following document:", uri = uri

  if uri notin ls.files.openFiles:
    return
  let fileInfo = ls.files.openFiles[uri]

  if fileInfo.changed:
    # check the file if it is closed but not saved.
    asyncSpawn ls.checkFile(uri)

  # Unassign from slot
  if fileInfo.slot != nil:
    fileInfo.slot.unassignUri(uri)

  ls.files.openFiles.del(uri)
  # Cancel any pending file check
  if fileInfo.cancelFileCheck != nil and not fileInfo.cancelFileCheck.finished:
    fileInfo.cancelFileCheck.complete()

proc makeIdleFile*(ls: LanguageServer, file: NlsFileInfo) =
  let uri = file.textDocument.uri
  if uri in ls.files.openFiles:
    ls.didCloseFile(uri)
    ls.files.idleOpenFiles[uri] = file

proc didClose*(
    ls: LanguageServer, params: DidCloseTextDocumentParams
): Future[void] {.async.} =
  ls.didCloseFile(params.textDocument.uri)

# === textDocument/didOpen ===

proc didOpenFile*(
  ls: LanguageServer, doc: TextDocumentItem
): Future[void] {.async.} =
  let uri = doc.uri
  if uri in ls.files.openFiles:
    debug "didOpenFile: URI already tracked, skipping", uri = uri
    return

  # Wait for config before making routing decisions (30s polling timeout)
  # THIS IS UNECESSARY NOW it is dealt with elsewhere.
  # await ls.waitForWorkspaceConfiguration()

# THIS IS UNECESSARY NOW
  # Re-check after the await in case concurrent open beat us
  # if uri in ls.files.openFiles:
  #   debug "didOpenFile: URI tracked after config wait (concurrent open), skipping",
  #     uri = uri
  #   return

  debug "New document opened for URI:", uri = uri

  # Find or create the slot for this URI (sync after config is ready)
  # IMPORTANT": This is the place where I need to check all currently running versions of nimsuggest, wait for ones that are spawning to finish, and then find out whether this new file exists in any of the existing slots.  If so, this file should use that slot.  If not, it needs to spawn it's own slot.



  # IMPORTANT: getOrCreateSlotForUri is a deeply flawed function that needs replacing. :(

  let slot = nimsuggestModule.getOrCreateSlotForUri(ls, uri)

  # Write the initial stash file
  let storagePath = ls.files.storageDir / (hash(uri).toHex & ".nim")
  try:
    writeFile(storagePath, doc.text)
  except IOError as ex:
    warn "Failed to write stash file; hover/completion may show stale content",
      path = storagePath, msg = ex.msg
  except OSError as ex:
    warn "Failed to write stash file; hover/completion may show stale content",
      path = storagePath, msg = ex.msg

  # Build finger table for UTF-16 mapping
  var fingerTable: seq[seq[tuple[u16pos, offset: int]]] = @[]
  for line in doc.text.splitLines:
    fingerTable.add line.createUTFMapping()

  # Register in the file table (sync, atomic)
  let fileInfo = NlsFileInfo(
    slot: slot,
    changed: false,
    fingerTable: fingerTable,
    textDocument: doc,
  )
  ls.files.openFiles[uri] = fileInfo

  if uri in ls.files.idleOpenFiles:
    ls.files.idleOpenFiles.del(uri)

  # Register ownership in the slot (sync, atomic with above)
  slot.assignUri(uri)

  # Spawn the slot's nimsuggest if not already running.
  # ns.isNone means the slot was just created (pre-SPAWNING state) but the
  # actual spawn hasn't been sent yet — send it now.
  if not slot.isActive or slot.ns.isNone:
    slot.send SlotCommand(
      kind: SlotCommandKind.SPAWN,
      spawnProjectFile: slot.projectFile,
      spawnTriggerUri: uri,
    )

  # Ask nimsuggest whether this file is in its module graph.
  # routingPolicy in the processor will handle any needed reassignment/respawn.
  slot.send SlotCommand(
    kind: SlotCommandKind.CHECK_KNOWN,
    checkUri: uri,
    checkIntendedProjectFile: nimsuggestModule.getIntendedProject(ls, uri),
  )

  debug "Opened file", uri = uri

proc didOpen*(
  ls: LanguageServer, params: DidOpenTextDocumentParams
): Future[void] {.async.} =
  await ls.didOpenFile(params.textDocument)


# === workspace/didRenameFiles ===
proc didRenameFile*(ls: LanguageServer, oldUri, newUri: string) =
  debug "File renamed", oldUri = oldUri, newUri = newUri

  # Move the stash file so any pending content checks use the right path
  let oldStash = ls.uriStorageLocation(oldUri)
  let newStash = ls.uriStorageLocation(newUri)
  if oldStash.fileExists:
    try:
      moveFile(oldStash, newStash)
    except Exception as e:
      debug "Failed to move stash file on rename",
        oldStash = oldStash, newStash = newStash, msg = e.msg

  # If a .nimble file was renamed, invalidate its dump cache entry
  let oldPath = uriToPath(oldUri)
  if oldPath.endsWith(".nimble"):
    ls.nimDumpCache.del(oldPath)
    ls.nimDumpCache.del(uriToPath(newUri))

  # If the file is currently open, migrate its entry to the new URI
  if oldUri in ls.files.openFiles:
    let fileInfo = ls.files.openFiles[oldUri]
    let slot = fileInfo.slot

    # Atomic rename in both tables (no await between)
    if slot != nil:
      slot.unassignUri(oldUri)
      slot.assignUri(newUri)
    ls.files.openFiles[newUri] = NlsFileInfo(
      slot: slot,
      changed: fileInfo.changed,
      fingerTable: fileInfo.fingerTable,
      textDocument: TextDocumentItem(
        uri: newUri,
        languageId: fileInfo.textDocument.languageId,
        version: fileInfo.textDocument.version,
        text: fileInfo.textDocument.text,
      ),
    )
    ls.files.openFiles.del(oldUri)

    # Clear diagnostics for the old URI unconditionally so the editor stops
    # showing stale errors on the now-gone path (fix #7).
    ls.sendDiagnostics(newSeq[Suggest](), oldPath)

    # Tell nimsuggest to rebuild its module graph
    if oldPath.endsWith(".nim") and slot != nil and slot.isLive:
      slot.send SlotCommand(kind: SlotCommandKind.RECOMPILE)

proc didRenameFiles*(
    ls: LanguageServer, params: RenameFilesParams
): Future[void] {.async.} =
  for rename in params.files:
    ls.didRenameFile(rename.oldUri, rename.newUri)

# === workspace/didDeleteFiles ===
proc didDeleteFile*(ls: LanguageServer, uri: string) =
  debug "File deleted", uri = uri
  let path = uriToPath(uri)

  # If a .nimble file was deleted, invalidate its dump cache entry
  if path.endsWith(".nimble"):
    ls.nimDumpCache.del(path)

  if uri in ls.files.openFiles:
    let fileInfo = ls.files.openFiles[uri]
    if fileInfo.slot != nil:
      fileInfo.slot.unassignUri(uri)
      if path.endsWith(".nim") and fileInfo.slot.isLive:
        fileInfo.slot.send SlotCommand(kind: SlotCommandKind.RECOMPILE)
    ls.files.openFiles.del(uri)
    
proc didDeleteFiles*(
    ls: LanguageServer, params: DeleteFilesParams
): Future[void] {.async.} =
  for file in params.files:
    ls.didDeleteFile(file.uri)

# === workspace/didChangeConfiguration ===

proc didChangeConfiguration*(
    ls: LanguageServer, conf: JsonNode
): Future[void] {.async.} =
  debug "Changed configuration: ", conf = conf
  if ls.usePullConfigurationModel:
    ls.maybeRequestConfigurationFromClient
  else:
    # Push model: client sent us the new config directly.
    let oldConfiguration = ls.getWorkspaceConfiguration()
    let newConfiguration = parseWorkspaceConfiguration(conf)
    ls.configurations.currentConfig = some(newConfiguration)
    ls.configurations.configReady.fire()
    # Restart all nimsuggest instances if settings that affect them changed.
    if oldConfiguration.nimsuggestPath != newConfiguration.nimsuggestPath or
        oldConfiguration.maxNimsuggestProcesses != newConfiguration.maxNimsuggestProcesses:
      ls.restartAllNimsuggestInstances()



proc didChangeConfiguration*(
  ls: LanguageServer, conf: JsonNode
): Future[void] {.async.} =
  debug "Changed configuration: ", conf = conf
  if ls.usePullConfigurationModel:
    ls.maybeRequestConfigurationFromClient
  else:
    # Push model: client sent us the new config directly.
    let oldConfiguration = ls.getWorkspaceConfiguration()
    let newConfiguration = parseWorkspaceConfiguration(conf)
    ls.configurations.currentConfig = some(newConfiguration)
    ls.configurations.configReady.fire()
    # Restart all nimsuggest instances if settings that affect them changed.
    if oldConfiguration.nimsuggestPath != newConfiguration.nimsuggestPath or
        oldConfiguration.maxNimsuggestProcesses != newConfiguration.maxNimsuggestProcesses:
      ls.restartAllNimsuggestInstances()
