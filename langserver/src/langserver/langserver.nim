import std/[
  os, macros, options,
  strformat, strutils, sequtils,
  hashes, tables, sets, setutils,
  json, times,
]

import chronos
import json_serialization
import json_rpc/[servers/socketserver]
import chronicles

import ../nimble/nimble_types
import ../nimsuggest/nimsuggest_types
import ../protocol/[enums, types]
import ../configurations/configuration_types
import ../nimsuggest/nimsuggest_slots
import ../configurations/constants
import ./[langserver_types, configurations, query_types, nimsuggest_processes]
import ../utils/utils as globalUtils

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
      openFiles: newTable[FileUri, NlsFileInfo](),
      idleOpenFiles: newTable[FileUri, NlsFileInfo](),
      filesWithDiags: initHashSet[FilePath](),
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
    lsInitialized: newFuture[void]("lsInitialized"),
  )
  # Create the pool synchronously so ls.pool is never nil when event loop starts.
  # initNimsuggestInstances will update maxSlots from config and spawn entry points.
  result.pool = newPool(
    slots = initTable[FilePath, NimsuggestSlot](),
    maxSlots = NIM_MAX_NS_PROCESSES,
  )
  result.pool.timeout = 120_000 ## REQUEST_TIMEOUT
  let ls = result # capture ref for the closures below
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
            projectFile: string(slot.projectFile),
            capabilities: ns.capabilities.toSeq,
            version: ns.version,
            path: ns.nimSuggestPath,
            port: ns.port,
          )
          for open in ns.openFiles.toSeq:
            nsStatus.openFiles.add string(open)
          result.nimsuggestInstances.add nsStatus
      except CatchableError:
        discard
  for openFile in ls.files.openFiles.keys:
    let openFilePath = uriToPath(openFile)
    result.openFiles.add string(openFilePath)

  result.pendingRequests = ls.messaging.pendingRequests.values.toSeq.map(toPendingRequestStatus)
  result.projectErrors = ls.messaging.projectErrors

proc sendStatusChanged*(ls: LanguageServer) {.raises: [].} =
  let status = %*ls.getLspStatus()
  if status != ls.messaging.lastStatusSent:
    ls.notify("extension/statusUpdate", status)
    ls.messaging.lastStatusSent = status

proc addProjectFileToPendingRequest*(ls: LanguageServer, id: uint, uri: FileUri) =
  # WHAT DOES THIS ACTUALLY DO?
  try:
    if id in ls.messaging.pendingRequests:
      ls.messaging.pendingRequests[id].projectFile = some string(uriToPath(uri))
      ls.sendStatusChanged
  except CatchableError as e:
    error "addProjectFileToPendingRequest failed", uri = uri, msg = e.msg

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

proc resolvedSlot(ls: LanguageServer, uri: FileUri): Option[NimsuggestSlot] =
  ## Return the current owning slot for uri, healing a stale fileInfo.slot
  ## pointer if execCheckKnown moved the URI to a different slot since open.
  let fileInfo = ls.files.openFiles.getOrDefault(uri)
  if fileInfo == nil:
    return none(NimsuggestSlot)
  if not fileInfo.slot.ownsUri(uri):
    let current = ls.pool.slotForUri(uri)
    if current.isNone:
      return none(NimsuggestSlot)
    fileInfo.slot = current.get
  some(fileInfo.slot)

proc nsCapabilities*(ls: LanguageServer, uri: FileUri): set[NimSuggestCapability] =
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

proc nsProtocolVersion*(ls: LanguageServer, uri: FileUri): int =
  ## Returns the nimsuggest protocol version for the slot serving `uri`.
  ## Safe to call synchronously after queryAt/queryFile returns.
  let slotOpt = ls.resolvedSlot(uri)
  if slotOpt.isNone:
    return 0
  let nsOpt = slotOpt.get.resolvedNs
  if nsOpt.isNone:
    return 0
  nsOpt.get.protocolVersion

proc tick*(ls: LanguageServer): Future[void] {.async.} =
  try:
    ls.removeCompletedPendingRequests()
    for slot in ls.idleSlots():
      # Send STOP and remove from pool FIRST so that any checkFile spawned by
      # makeIdleFile routes through an already-stopped slot and gets @[] cleanly,
      # rather than racing with a live TCP connection being torn down.
      debug "Removing idle nimsuggest", projectFile = slot.projectFile
      discard await execStop(slot, ls.pool)
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
          ls.files.idleOpenFiles[uri] = fileInfo
          ls.files.openFiles.del(uri)
    ls.sendStatusChanged
  except CatchableError as ex:
    error "Error in tick", msg = ex.msg
    writeStacktrace(ex)


