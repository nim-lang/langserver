import std/[os, options, hashes, sets, strformat, sugar, sequtils, strutils]
import chronos
import chronicles

import ../protocol/types
import ../nimsuggest/[nimsuggest_types, nimsuggest]
import ../nimcheck/nimcheck
import ../nim_compiler/nim_compiler
import ./[configurations, langserver_types, constants, utils, queue_types, queues, diagnostics]
import ../requests/requests

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

    # Clear any active diagnostics for the old URI so the editor stops
    # showing stale errors on the now-gone path (fix #7).
    if oldPath in ls.files.filesWithDiags:
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

  # Spawn the slot's nimsuggest if not already running
  if not slot.isActive:
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
