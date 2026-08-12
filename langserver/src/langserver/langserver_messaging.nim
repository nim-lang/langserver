import std/[
  os, macros, 
  options,
  strformat, 
  strutils, sequtils,
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

import ./[langserver_types, query_types, langserver_nimsuggest]

proc showMessage*(
  ls: LanguageServer, message: string, typ: MessageType
) {.raises: [].} =
  try:
    proc notify() =
      ls.notify("window/showMessage", %*{"type": typ.int, "message": message})

    let verbosity = ls.configurations.currentConfig.notificationVerbosity
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


proc progressSupported*(ls: LanguageServer): bool =
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

proc removeCompletedPendingRequests*(
    ls: LanguageServer, 
    maxTimeAfterRequestWasCompleted = initDuration(seconds = 10) # TODO - this setting should probably be in the configuration
) =
  var toRemove = newSeq[uint]()
  for id, pr in ls.messaging.pendingRequests:
    if pr.state != prsOnGoing:
      let passedTime = now() - pr.endTime
      if passedTime > maxTimeAfterRequestWasCompleted:
        toRemove.add id

  for id in toRemove:
    ls.messaging.pendingRequests.del id


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
          for open in ns.openFiles.toSeq():
            nsStatus.openFiles.add string(open)
          result.nimsuggestInstances.add nsStatus
      except CatchableError:
        discard
  for openFile in ls.files.openFiles.keys:
    let openFilePath = uriToPath(openFile)
    result.openFiles.add string(openFilePath)

  result.pendingRequests = ls.messaging.pendingRequests.values.toSeq().map(toPendingRequestStatus)
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
      ls.sendStatusChanged()
  except CatchableError as e:
    error "addProjectFileToPendingRequest failed", uri = uri, msg = e.msg

