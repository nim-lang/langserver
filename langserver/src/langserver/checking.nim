import std/[options, sets, sequtils, strformat, sugar, json]
import chronos
import chronicles

import ../protocol/types
import ../nimsuggest/[nimsuggest_types, suggestapi_types, nimsuggest_slots]
import ../nim_check/nim_check
import ../nim_compiler/nim_compiler
import ../configurations/constants
import ./[configurations, langserver_types, utils, dispatcher_utils, diagnostics, langserver]
import ../utils/utils as globalUtils


proc checkFile*(ls: LanguageServer, uri: FileUri): Future[void] {.async.} =
  if uri notin ls.files.openFiles:
    return
  let fileInfo = ls.files.openFiles[uri]
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
  ls.sendDiagnostics(results.filter(s => string(s.filePath) != "???"), path)


proc scheduleFileCheck*(ls: LanguageServer, uri: FileUri) {.gcsafe, raises: [].} =
  if not ls.getWorkspaceConfiguration().autoCheckFile.get(true):
    return
  # schedule file check after the file is modified
  let fileData = ls.files.openFiles.getOrDefault(uri)
  if fileData.cancelFileCheck != nil and not fileData.cancelFileCheck.finished:
    fileData.cancelFileCheck.complete()

  if fileData.checkInProgress:
    fileData.needsChecking = true
    return

  var cancelFuture = newFuture[void]()
  fileData.cancelFileCheck = cancelFuture

  proc doCheck() {.async.} =
    await sleepAsync(FILE_CHECK_DELAY)
    if not cancelFuture.finished:
      fileData.checkInProgress = true
      try:
        await ls.checkFile(uri)
      except CatchableError:
        discard
      try:
        ls.files.openFiles[uri].checkInProgress = false
        if fileData.needsChecking:
          fileData.needsChecking = false
          ls.scheduleFileCheck(uri)
      except KeyError:
        discard
  asyncSpawn doCheck()

proc cancelPendingFileChecks*(ls: LanguageServer, slot: NimsuggestSlot) =
  ## Cancel file-level checks for all URIs owned by this slot.
  for uri in slot.ownedUris:
    let fileData = ls.files.openFiles.getOrDefault(uri)
    if fileData != nil:
      let cancelFileCheck = fileData.cancelFileCheck
      if cancelFileCheck != nil and not cancelFileCheck.finished:
        cancelFileCheck.complete()
      fileData.needsChecking = false

proc checkProject*(ls: LanguageServer, uri: FileUri): Future[void] {.async.} =
  if ls.checkInProgress:
    return
  ls.checkInProgress = true
  defer:
    ls.checkInProgress = false

  let conf = ls.getWorkspaceConfiguration()
  if not conf.autoCheckProject.get(true):
    return
  let useNimCheck = conf.useNimCheck.get(USE_NIM_CHECK_BY_DEFAULT)
  let nimPath = getNimPath(conf)

  if useNimCheck and nimPath.isSome:
    proc getFilePath(c: CheckResult): FilePath = c.file
    let token = fmt "Checking {uri}"
    ls.workDoneProgressCreate(token)
    ls.progress(token, "begin", fmt "Checking project {uri}")
    if string(uri) == "":
      warn "Checking project with empty uri", uri = uri
      ls.progress(token, "end")
      return
    let diagnostics = await nimCheck(uriToPath(uri), nimPath.get)
    let filesWithDiags = diagnostics.map(r => r.file).toHashSet
    ls.progress(token, "end")

    debug "Found diagnostics", file = filesWithDiags
    for (path, diags) in groupBy(diagnostics, getFilePath):
      ls.sendDiagnostics(diags, path)

    for path in ls.files.filesWithDiags:
      if not filesWithDiags.contains path:
        debug "Sending zero diags", path = path
        let params =
          PublishDiagnosticsParams %* {"uri": pathToUri(path), "diagnostics": @[]}
        ls.notify("textDocument/publishDiagnostics", %params)
    ls.files.filesWithDiags = filesWithDiags
    return

  debug "Running diagnostics", uri = uri
  # Use the slot for this URI
  let slotOpt =
    if ls.pool != nil: ls.pool.slotForUri(uri)
    else: none(NimsuggestSlot)
  if slotOpt.isNone or not slotOpt.get.isLive:
    return
  let slot = slotOpt.get

  ls.cancelPendingFileChecks(slot)

  let token = fmt "Checking {uri}"
  ls.workDoneProgressCreate(token)
  ls.progress(token, "begin", fmt "Checking project {uri.uriToPath}")

  let diagnostics = await ls.queryFile(uri, NimsuggestQueryKind.CHECK_PROJECT)
  ls.progress(token, "end")

  proc getFilepath(s: Suggest): FilePath = s.filePath

  let filtered = diagnostics.filter(sug => string(sug.filePath) != "???")
  let filesWithDiags = filtered.map(s => s.filePath).toHashSet

  for (path, diags) in groupBy(filtered, getFilepath):
    ls.sendDiagnostics(diags, path)

  for path in ls.files.filesWithDiags:
    if not filesWithDiags.contains path:
      debug "Sending zero diags", path = path
      let params =
        PublishDiagnosticsParams %* {"uri": pathToUri(path), "diagnostics": @[]}
      ls.notify("textDocument/publishDiagnostics", %params)
  ls.files.filesWithDiags = filesWithDiags


