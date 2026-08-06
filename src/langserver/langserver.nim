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

import ../nim_tools/nimble/nimble
import ../nim_tools/nimsuggest/[suggestapi, nimsuggest, nimsuggest_types]
import ../nim_tools/nimcheck/nimcheck
import ../nim_tools/compiler/nim_compiler
import ../protocol/[enums, types]
import ./[constants, utils, langserver_types, configuration_types, messaging_types, configurations, diagnostics, files, queues, queue_types]

proc sendStatusChanged*(ls: LanguageServer) {.raises: [].}

proc initLanguageServer*(params: CommandLineParams, storageDir: string): LanguageServer =
  let configReady = newAsyncEvent()
  result = LanguageServer(
    capabilities: LanguageServerCapabilities(
      serverMode: params.mode.get(ServerMode.lsp),
      extensionCapabilities: LspExtensionCapability.items.toSet,
    ),
    configurations: LanguageServerConfigurations(
      currentConfig: none(NlsConfig),
      configReady: configReady,
    ),
    transport: LanguageServerTransport(
      transportMode: params.transport.get(TransportMode.stdio),
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
      responseNames: newTable[string, string](),
      projectErrors: @[],
    ),
    nimDumpCache: initTable[string, NimbleDumpInfo](),
    cmdLineClientProcessId: params.clientProcessId,
    lspQueue: newAsyncQueue[LspDispatchItem](),
    langserverQueue: newAsyncQueue[LangserverQuery](),
  )
  # Create the pool synchronously so ls.pool is never nil when event loop starts.
  # initNimsuggestInstances will update maxSlots from config and spawn entry points.
  result.pool = newPool(
    maxSlots = NIM_MAX_NS_PROCESSES,
    spawnProc = makeSpawnProc(result),
    stopProc = makeStopProc(),
    isKnownProc = makeIsKnownProc(),
  )
  let ls = result # capture ref for the closure below
  result.pool.notifyProc = proc(meth: string, params: JsonNode) {.gcsafe, raises: [].} =
    ls.notify(meth, params)
  result.pool.statusChangedProc = proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      ls.sendStatusChanged()

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
          for open in ns.openFiles.toSeq:
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

proc addProjectFileToPendingRequest*(ls: LanguageServer, id: uint, uri: string) =
  # WHAT DOES THIS ACTUALLY DO?
  try:
    if id in ls.messaging.pendingRequests:
      ls.messaging.pendingRequests[id].projectFile = some uri.uriToPath()
      ls.sendStatusChanged
  except CatchableError as e:
    error "addProjectFileToPendingRequest failed", uri = uri, msg = e.msg

# proc getProjectFileAutoGuess*(
#     ls: LanguageServer, fileUri: string
# ): Future[string] {.async.} =
#   let file = fileUri.decodeUrl
#   debug "Auto-guessing project file for", file = file
#   result = file
#   let (dir, _, _) = result.splitFile()
#   var
#     path = dir
#     certainty = Certainty.None
#     up = 0

#   let conf = ls.getWorkspaceConfiguration()
#   let maxNimsuggestProcesses = conf.maxNimsuggestProcesses.get(NIM_MAX_NS_PROCESSES)
#   let maxUp = if maxNimsuggestProcesses == 1: 0 else: 2
#   while path.len > 0 and path != "/" and up < maxUp:
#     let
#       (dir, fname, ext) = path.splitFile()
#       current = fname & ext
#     if fileExists(path / current.addFileExt(".nim")) and certainty <= Folder:
#       result = path / current.addFileExt(".nim")
#       certainty = Folder
#     if fileExists(path / current.addFileExt(".nim")) and (
#       fileExists(path / current.addFileExt(".nim.cfg")) or
#       fileExists(path / current.addFileExt(".nims"))
#     ) and certainty <= Cfg:
#       result = path / current.addFileExt(".nim")
#       certainty = Cfg
#     if certainty <= Nimble:
#       for nimble in walkFiles(path / "*.nimble"):
#         let dumpInfo = await ls.getNimbleDumpInfo(nimble)
#         let name = dumpInfo.name
#         let sourceDir = path / dumpInfo.srcDir
#         let projectFile = sourceDir / (name & ".nim")
#         if sourceDir.len != 0 and name.len != 0 and file.isRelTo(sourceDir) and
#             fileExists(projectFile):
#           debug "Found nimble project", projectFile = projectFile
#           result = projectFile
#           certainty = Nimble
#           return
#     if path == dir:
#       break
#     path = dir
#     inc up

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

# proc cancelPendingFileChecks*(ls: LanguageServer, slot: NimsuggestSlot) =
#   ## Cancel file-level checks for all URIs owned by this slot.
#   for uri in slot.ownedUris:
#     let fileData = ls.files.openFiles.getOrDefault(uri)
#     if fileData != nil:
#       let cancelFileCheck = fileData.cancelFileCheck
#       if cancelFileCheck != nil and not cancelFileCheck.finished:
#         cancelFileCheck.complete()
#       fileData.needsChecking = false

# proc checkProject*(ls: LanguageServer, uri: string): Future[void] {.async.} =
#   if ls.checkInProgress:
#     return
#   ls.checkInProgress = true
#   defer:
#     ls.checkInProgress = false

#   let conf = ls.getWorkspaceConfiguration()
#   if not conf.autoCheckProject.get(true):
#     return
#   let useNimCheck = conf.useNimCheck.get(USE_NIM_CHECK_BY_DEFAULT)
#   let nimPath = getNimPath(conf)

#   if useNimCheck and nimPath.isSome:
#     proc getFilePath(c: CheckResult): string = c.file
#     let token = fmt "Checking {uri}"
#     ls.workDoneProgressCreate(token)
#     ls.progress(token, "begin", fmt "Checking project {uri}")
#     if uri == "":
#       warn "Checking project with empty uri", uri = uri
#       ls.progress(token, "end")
#       return
#     let diagnostics = await nimCheck(uriToPath(uri), nimPath.get)
#     let filesWithDiags = diagnostics.map(r => r.file).toHashSet
#     ls.progress(token, "end")

#     debug "Found diagnostics", file = filesWithDiags
#     for (path, diags) in groupBy(diagnostics, getFilePath):
#       ls.sendDiagnostics(diags, path)

#     for path in ls.files.filesWithDiags:
#       if not filesWithDiags.contains path:
#         debug "Sending zero diags", path = path
#         let params =
#           PublishDiagnosticsParams %* {"uri": pathToUri(path), "diagnostics": @[]}
#         ls.notify("textDocument/publishDiagnostics", %params)
#     ls.files.filesWithDiags = filesWithDiags
#     return

#   debug "Running diagnostics", uri = uri
#   # Use the slot for this URI
#   let slotOpt =
#     if ls.pool != nil: ls.pool.slotForUri(uri)
#     else: none(NimsuggestSlot)
#   if slotOpt.isNone or not slotOpt.get.isLive:
#     return
#   let slot = slotOpt.get

#   ls.cancelPendingFileChecks(slot)

#   let token = fmt "Checking {uri}"
#   ls.workDoneProgressCreate(token)
#   ls.progress(token, "begin", fmt "Checking project {uri.uriToPath}")

#   let q = NimsuggestQuery(
#     kind: NimsuggestQueryKind.CHECK_PROJECT,
#     uri: uri,
#     dirtyFile: ls.uriToStash(uri),
#     responseFuture: newFuture[seq[Suggest]]("checkProject"),
#   )
#   let diagnostics = await slot.query(q)
#   ls.progress(token, "end")

#   proc getFilepath(s: Suggest): string = s.filePath

#   let filtered = diagnostics.filter(sug => sug.filePath != "???")
#   let filesWithDiags = filtered.map(s => s.filePath).toHashSet

#   for (path, diags) in groupBy(filtered, getFilepath):
#     ls.sendDiagnostics(diags, path)

#   for path in ls.files.filesWithDiags:
#     if not filesWithDiags.contains path:
#       debug "Sending zero diags", path = path
#       let params =
#         PublishDiagnosticsParams %* {"uri": pathToUri(path), "diagnostics": @[]}
#       ls.notify("textDocument/publishDiagnostics", %params)
#   ls.files.filesWithDiags = filesWithDiags

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

proc resolvedSlot(ls: LanguageServer, uri: string): Option[NimsuggestSlot] =
  ## Return the current owning slot for uri, healing a stale fileInfo.slot
  ## pointer if execCheckKnown moved the URI to a different slot since open.
  let fileInfo = ls.files.openFiles.getOrDefault(uri)
  if fileInfo == nil or fileInfo.slot == nil:
    return none(NimsuggestSlot)
  if not fileInfo.slot.ownsUri(uri):
    let current = ls.pool.slotForUri(uri)
    if current.isNone:
      return none(NimsuggestSlot)
    fileInfo.slot = current.get
  some(fileInfo.slot)

proc nsCapabilities*(ls: LanguageServer, uri: string): set[NimSuggestCapability] =
  ## Returns the live nimsuggest capabilities for the slot serving `uri`.
  ## Safe to call synchronously after queryAt/queryFile returns — by that point
  ## processQueries has already awaited slot.ns.get so the slot is READY.
  let slotOpt = ls.resolvedSlot(uri)
  if slotOpt.isNone:
    return {}
  let nsOpt = slotOpt.get.resolvedNs
  if nsOpt.isNone:
    return {}
  nsOpt.get.capabilities

proc nsProtocolVersion*(ls: LanguageServer, uri: string): int =
  ## Returns the nimsuggest protocol version for the slot serving `uri`.
  ## Safe to call synchronously after queryAt/queryFile returns.
  let slotOpt = ls.resolvedSlot(uri)
  if slotOpt.isNone:
    return 0
  let nsOpt = slotOpt.get.resolvedNs
  if nsOpt.isNone:
    return 0
  nsOpt.get.protocolVersion

# proc tryGetNimsuggest*(ls: LanguageServer, uri: string): Future[Option[NimSuggest]] {.async.} =
#   ## Compatibility helper: returns the live NimSuggest for the slot serving `uri`,
#   ## or none if the slot isn't ready. Awaits spawning if the slot is currently starting.
#   let fileInfo = ls.files.openFiles.getOrDefault(uri)
#   if fileInfo == nil:
#     return none(NimSuggest)
#   let slot = fileInfo.slot
#   if slot == nil:
#     return none(NimSuggest)
#   if slot.ns.isSome:
#     try:
#       discard await slot.ns.get
#     except CatchableError:
#       return none(NimSuggest)
#   return slot.resolvedNs

proc tick*(ls: LanguageServer): Future[void] {.async.} =
  try:
    ls.removeCompletedPendingRequests()
    for slot in ls.idleSlots():
      # Send STOP and remove from pool FIRST so that any checkFile spawned by
      # makeIdleFile routes through an already-stopped slot and gets @[] cleanly,
      # rather than racing with a live TCP connection being torn down.
      debug "Removing idle nimsuggest", projectFile = slot.projectFile
      slot.send SlotCommand(kind: SlotCommandKind.STOP)
      ls.pool.removeSlot(slot.projectFile)
      ls.notify("window/showMessage", %*{
        "type": MessageType.Info.int,
        "message": fmt"Nimsuggest for {slot.projectFile} was stopped because it was idle for too long",
      })
      # Evict owned open files to idleOpenFiles so they re-open silently on next use.
      # Use direct table lookup (not withValue) to avoid holding a pointer into the
      # table's internal storage across the makeIdleFile call, which calls
      # openFiles.del(uri) and can invalidate that pointer.
      for uri in slot.ownedUris.toSeq:
        if uri in ls.files.openFiles:
          let fileInfo = ls.files.openFiles[uri]
          ls.makeIdleFile(fileInfo)
    ls.sendStatusChanged
  except CatchableError as ex:
    error "Error in tick", msg = ex.msg
    writeStacktrace(ex)
