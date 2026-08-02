import std/[
  os, osproc, macros, options,
  strformat, strutils, sequtils, sugar, with,
  hashes, tables, sets, setutils,
  json, streams, times, uri,
]

import chronos/[threadsync, asyncproc]
import stew/byteutils
import json_serialization
import json_rpc/[servers/socketserver]
import chronicles

import ../nimble/nimble
import ../nimsuggest/[suggestapi, nimsuggest, nimsuggest_types]
import ../nimcheck/nimcheck
import ../nim_compiler/nim_compiler
import ../protocol/[enums, types]
import ./[constants, utils, langserver_types, configuration_types, messaging_types, configurations, diagnostics, files, queues, queue_types]


proc initLanguageServer*(params: CommandLineParams, storageDir: string): LanguageServer =
  let configReady = newAsyncEvent()
  result = LanguageServer(
    capabilities: LanguageServerCapabiities(
      serverMode: params.mode.get(),
      extensionCapabilities: LspExtensionCapability.items.toSet,
    ),
    configurations: LanguageServerConfigurations(
      currentConfig: none(NlsConfig),
      configReady: configReady,
    ),
    transport: LanguageServerTransport(
      transportMode: params.transport.get(),
    ),
    files: LanguageServerFiles(
      openFiles: initTable[string, NlsFileInfo](),
      idleOpenFiles: initTable[string, NlsFileInfo](),
      filesWithDiags: initHashSet[string](),
      storageDir: storageDir,
    ),
    messaging: LanguageServerMessaging(
      pendingRequests: initTable[uint, PendingRequest](),
      responseMap: newTable[string, Future[JsonNode]](),
      projectErrors: @[],
    ),
    nimDumpCache: initTable[string, NimbleDumpInfo](),
    cmdLineClientProcessId: params.clientProcessId,
  )
  # pool is initialized later by initNimsuggestInstances

proc supportSignatureHelp*(cc: LspClientCapabilities): bool =
  if cc.isNil:
    return false
  let caps = cc.textDocument
  caps.isSome and caps.get.signatureHelp.isSome

proc showMessage*(
    ls: LanguageServer, message: string, typ: MessageType
) {.raises: [].} =
  try:
    proc notify() =
      ls.notify("window/showMessage", %*{"type": typ.int, "message": message})

    let verbosity = ls.getWorkspaceConfiguration().notificationVerbosity.get(
      NlsNotificationVerbosity.nvInfo
    )
    debug "ShowMessage", message = message
    case verbosity
    of nvInfo:
      notify()
    of nvWarning:
      if typ.int <= MessageType.Warning.int:
        notify()
    of nvError:
      if typ == MessageType.Error:
        notify()
    else:
      discard
  except CatchableError:
    discard

proc applyEdit*(
    ls: LanguageServer, params: ApplyWorkspaceEditParams
): Future[ApplyWorkspaceEditResponse] {.async.} =
  let res = await ls.call("workspace/applyEdit", %params)
  res.to(ApplyWorkspaceEditResponse)

proc toPendingRequestStatus(pr: PendingRequest): PendingRequestStatus =
  result.time =
    case pr.state
    of prsOnGoing:
      $(now() - pr.startTime)
    else:
      $(pr.endTime - pr.startTime)
  result.name = pr.name
  result.projectFile = pr.projectFile.get("")
  result.state = $pr.state

proc getLspStatus*(ls: LanguageServer): NimLangServerStatus {.raises: [].} =
  result.lspPath = getAppFilename()
  result.version = LSPVersion
  result.extensionCapabilities = ls.capabilities.extensionCapabilities.toSeq
  var seenPorts = initHashSet[int]()
  if ls.pool != nil:
    for slot in ls.pool.slots.values:
      try:
        let nsOpt = slot.resolvedNs
        if nsOpt.isSome:
          let ns = nsOpt.get
          if ns.port in seenPorts:
            continue
          seenPorts.incl(ns.port)
          var nsStatus = NimSuggestStatus(
            projectFile: slot.projectFile,
            capabilities: ns.capabilities.toSeq,
            version: ns.version,
            path: ns.nimSuggestPath,
            port: ns.port,
          )
          for open in ns.openFiles:
            nsStatus.openFiles.add open
          result.nimsuggestInstances.add nsStatus
      except CatchableError:
        discard
  for openFile in ls.files.openFiles.keys:
    let openFilePath = openFile.uriToPath
    result.openFiles.add openFilePath

  result.pendingRequests = ls.messaging.pendingRequests.values.toSeq.map(toPendingRequestStatus)
  result.projectErrors = ls.messaging.projectErrors

proc sendStatusChanged*(ls: LanguageServer) {.raises: [].} =
  let status = %*ls.getLspStatus()
  if status != ls.messaging.lastStatusSent:
    ls.notify("extension/statusUpdate", status)
    ls.messaging.lastStatusSent = status

proc addProjectFileToPendingRequest*(
    ls: LanguageServer, id: uint, uri: string
) {.async.} =
  try:
    if id in ls.messaging.pendingRequests:
      let projectFile = uri.uriToPath()
      ls.messaging.pendingRequests[id].projectFile = some projectFile
      ls.sendStatusChanged
  except CancelledError:
    discard
  except CatchableError as e:
    error "addProjectFileToPendingRequest failed", uri = uri, msg = e.msg

proc getProjectFileAutoGuess*(
    ls: LanguageServer, fileUri: string
): Future[string] {.async.} =
  let file = fileUri.decodeUrl
  debug "Auto-guessing project file for", file = file
  result = file
  let (dir, _, _) = result.splitFile()
  var
    path = dir
    certainty = Certainty.None
    up = 0

  let conf = ls.getWorkspaceConfiguration()
  let maxNimsuggestProcesses = conf.maxNimsuggestProcesses.get(NIM_MAX_NS_PROCESSES)
  let maxUp = if maxNimsuggestProcesses == 1: 0 else: 2
  while path.len > 0 and path != "/" and up < maxUp:
    let
      (dir, fname, ext) = path.splitFile()
      current = fname & ext
    if fileExists(path / current.addFileExt(".nim")) and certainty <= Folder:
      result = path / current.addFileExt(".nim")
      certainty = Folder
    if fileExists(path / current.addFileExt(".nim")) and (
      fileExists(path / current.addFileExt(".nim.cfg")) or
      fileExists(path / current.addFileExt(".nims"))
    ) and certainty <= Cfg:
      result = path / current.addFileExt(".nim")
      certainty = Cfg
    if certainty <= Nimble:
      for nimble in walkFiles(path / "*.nimble"):
        let dumpInfo = await ls.getNimbleDumpInfo(nimble)
        let name = dumpInfo.name
        let sourceDir = path / dumpInfo.srcDir
        let projectFile = sourceDir / (name & ".nim")
        if sourceDir.len != 0 and name.len != 0 and file.isRelTo(sourceDir) and
            fileExists(projectFile):
          debug "Found nimble project", projectFile = projectFile
          result = projectFile
          certainty = Nimble
          return
    if path == dir:
      break
    path = dir
    inc up

proc progressSupported(ls: LanguageServer): bool =
  result = ls.capabilities.serverMode == lsp and
    ls.capabilities.lspInitializeParams.capabilities.window
      .get(ClientCapabilities_window()).workDoneProgress
      .get(false)

proc progress*(ls: LanguageServer, token, kind: string, title = "") =
  if ls.progressSupported:
    ls.notify("$/progress", %*{"token": token, "value": {"kind": kind, "title": title}})

proc workDoneProgressCreate*(ls: LanguageServer, token: string) =
  if ls.progressSupported:
    discard ls.call("window/workDoneProgress/create", %ProgressParams(token: token))

proc cancelPendingFileChecks*(ls: LanguageServer, slot: NimsuggestSlot) =
  ## Cancel file-level checks for all URIs owned by this slot.
  for uri in slot.ownedUris:
    let fileData = ls.files.openFiles.getOrDefault(uri)
    if fileData != nil:
      let cancelFileCheck = fileData.cancelFileCheck
      if cancelFileCheck != nil and not cancelFileCheck.finished:
        cancelFileCheck.complete()
      fileData.needsChecking = false

proc checkProject*(ls: LanguageServer, uri: string): Future[void] {.async.} =
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
    proc getFilePath(c: CheckResult): string = c.file
    let token = fmt "Checking {uri}"
    ls.workDoneProgressCreate(token)
    ls.progress(token, "begin", fmt "Checking project {uri}")
    if uri == "":
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

  let q = NimsuggestQuery(
    kind: NimsuggestQueryKind.CHECK_PROJECT,
    uri: uri,
    dirtyFile: ls.uriToStash(uri),
    responseFuture: newFuture[seq[Suggest]]("checkProject"),
  )
  let diagnostics = await slot.query(q)
  ls.progress(token, "end")

  proc getFilepath(s: Suggest): string = s.filePath

  let filtered = diagnostics.filter(sug => sug.filePath != "???")
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

proc removeCompletedPendingRequests(
    ls: LanguageServer, maxTimeAfterRequestWasCompleted = initDuration(seconds = 10)
) =
  var toRemove = newSeq[uint]()
  for id, pr in ls.messaging.pendingRequests:
    if pr.state != prsOnGoing:
      let passedTime = now() - pr.endTime
      if passedTime > maxTimeAfterRequestWasCompleted:
        toRemove.add id

  for id in toRemove:
    ls.messaging.pendingRequests.del id

proc tryGetNimsuggest*(ls: LanguageServer, uri: string): Future[Option[NimSuggest]] {.async.} =
  ## Compatibility helper: returns the live NimSuggest for the slot serving `uri`,
  ## or none if the slot isn't ready. Awaits spawning if the slot is currently starting.
  let fileInfo = ls.files.openFiles.getOrDefault(uri)
  if fileInfo == nil:
    return none(NimSuggest)
  let slot = fileInfo.slot
  if slot == nil:
    return none(NimSuggest)
  if slot.ns.isSome:
    try:
      discard await slot.ns.get
    except CatchableError:
      return none(NimSuggest)
  return slot.resolvedNs

proc tick*(ls: LanguageServer): Future[void] {.async.} =
  try:
    ls.removeCompletedPendingRequests()
    await ls.removeIdleNimsuggests()
    ls.sendStatusChanged
  except CatchableError as ex:
    error "Error in tick", msg = ex.msg
    writeStacktrace(ex)
