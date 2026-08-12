import std/[
  os, macros, options,
  strformat, strutils, sequtils,
  hashes, tables, sets, setutils,
  json, times, tables
]

import chronos
import json_serialization
import json_rpc/[servers/socketserver]
import chronicles

import ../nimble/nimble_types
import ../protocol/[enums, types]
import ../configurations/configurations
import ../nimsuggest/nimsuggest
import ../utils/utils

import ./[langserver_types, query_types, langserver_nimsuggest, langserver_messaging]

# proc sendStatusChanged*(ls: LanguageServer) {.raises: [].}

proc initLanguageServer*(params: CommandLineParams, storageDir: string): LanguageServer =
  let currentConfig = initDefaultNlsConfig()
  let configReady = newAsyncEvent()
  result = LanguageServer(
    capabilities: LanguageServerCapabilities(
      serverMode: params.mode.get(ServerMode.lsp),
      extensionCapabilities: LspExtensionCapability.items.toSet,
    ),
    configurations: LanguageServerConfigurations(
      currentConfig: initDefaultNlsConfig(),
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
  let ls = result
  result.pool = NimsuggestPool(
    slots: initTable[FilePath, NimsuggestSlot](), 
    maxSlots: currentConfig.maxNimsuggestProcesses, 
    fileCheckDelay: initDuration(milliseconds = currentConfig.fileCheckDelay),
    timeout: currentConfig.langserverTimeout,
    nimsuggestPath: currentConfig.nimsuggestPath, # Set in initNimsuggestInstances
    nimVersion: "", # Set in initNimsuggestInstances
    notifyProc: proc(meth: string, params: JsonNode) {.gcsafe, raises: [].} =
    ls.notify(meth, params),
    statusChangedProc: proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      ls.sendStatusChanged()
  )

proc tick*(ls: LanguageServer): Future[void] {.async.} =
  try:
    ls.removeCompletedPendingRequests()
    for slot in ls.pool.idleSlots(ls.configurations.currentConfig):
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
