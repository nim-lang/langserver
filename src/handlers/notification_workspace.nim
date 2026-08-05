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
