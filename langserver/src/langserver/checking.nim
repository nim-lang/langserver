import std/[options, sets, sequtils, strformat, sugar, json, times]
import chronos
import chronicles

import ../protocol/types
import ../nimsuggest/[nimsuggest_types, suggestapi_types, nimsuggest_slots]
import ../configurations/constants
import ./[configurations, langserver_types, utils, dispatcher_utils, diagnostics, langserver]
import ../utils/utils as globalUtils

proc checkProject*(ls: LanguageServer, uri: FileUri): Future[void] {.async.} =
  if ls.checkInProgress:
    return
  ls.checkInProgress = true
  defer:
    ls.checkInProgress = false

  debug "Running diagnostics", uri = uri
  # Use the slot for this URI
  let slotOpt =
    if ls.pool != nil: ls.pool.slotForUri(uri)
    else: none(NimsuggestSlot)
  if slotOpt.isNone or not slotOpt.get.isLive:
    return
  let slot = slotOpt.get

  let token = fmt "Checking {uri}"
  ls.workDoneProgressCreate(token)
  ls.progress(token, "begin", fmt"Checking project {string(slot.projectFile)}")
  # Send chk with the slot's project file, not the saved URI. nimsuggest's chk
  # command takes the entry-point path it was spawned with; any other file would
  # cause it to check the wrong scope.
  let chkQuery = NimsuggestQuery[LspFilePosition](
    id: 0,
    kind: NimsuggestQueryKind.CHECK_PROJECT,
    uri: pathToUri(slot.projectFile),
    dirtyFile: FilePath(""),
    responseFuture: newFuture[seq[Suggest]]("checkProject"),
  )
  slot.queryMailbox.addLastNoWait(chkQuery)
  let diagnostics = await chkQuery.responseFuture
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

  # Suppress per-file rechecks: checkProject already compiled everything the slot owns.
  let now = times.now()
  for slotUri in slot.ownedUris:
    let fileInfo = ls.files.openFiles.getOrDefault(slotUri)
    if fileInfo != nil:
      fileInfo.lastChecked = now


proc tickFileChecks*(ls: LanguageServer): Future[void] {.async.} =
  ## Periodic loop that runs chkFile for files with unseen edits that have
  ## been quiet for at least FILE_CHECK_DELAY ms. Sequential: awaits each
  ## checkFile so only one chkFile is in-flight at a time.
  while true:
    let fileCheckDelayMs = ls.getWorkspaceConfiguration().fileCheckDelay.get(FILE_CHECK_DELAY)
    await sleepAsync(fileCheckDelayMs)
    if not ls.getWorkspaceConfiguration().autoCheckFile.get(true):
      continue
    let now = times.now()
    let delay = initDuration(milliseconds = fileCheckDelayMs)
    # Snapshot keys to avoid mutating the table while iterating across awaits.
    for uri in ls.files.openFiles.keys.toSeq:
      let fileInfo = ls.files.openFiles.getOrDefault(uri)
      if fileInfo == nil: continue
      if fileInfo.lastEditTime > fileInfo.lastChecked and
         now - fileInfo.lastEditTime >= delay:
        # Set lastChecked before awaiting so the next tick doesn't re-trigger
        # for the same edit even if checkFile is still running.
        debug "Checking file:", file = uri
        fileInfo.lastChecked = times.now()
        let checkQuery = await ls.queryFile(uri, NimsuggestQueryKind.CHECK_FILE)
        ls.sendDiagnostics(checkQuery.filter(s => string(s.filePath) != "???"), uriToPath(uri))
