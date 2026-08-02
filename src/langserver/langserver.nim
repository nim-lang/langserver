import std/[
  os, osproc, macros,
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
import ../nimsuggest/[suggestapi, nimsuggest]
import ../nimcheck/nimcheck
import ../nim_compiler/nim_compiler
import ../protocol/[enums, types]
import ./[constants, utils, langserver_types, configuration_types, messaging_types, configurations, diagnostics, files]


proc initLanguageServer*(params: CommandLineParams, storageDir: string): LanguageServer =
  LanguageServer(
    capabilities: LanguageServerCapabiities(
      serverMode: params.mode.get(),
      extensionCapabilities: LspExtensionCapability.items.toSet,
    ),
    configurations: LanguageServerConfigurations(
      workspaceConfiguration: newFuture[JsonNode]("workspaceConfiguration"),
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
    nimsuggest: LanguageServerNimSuggest(
      nimsuggestInstances: initTable[ProjectFile, Project](),
      entryPoints: @[],
      failTable: initTable[ProjectFile, int](),
      crashedFiles: initTable[ProjectFile, HashSet[string]](),
      nimDumpCache: initTable[ProjectFile, NimbleDumpInfo](),
    ),
    messaging: LanguageServerMessaging(
      pendingRequests: initTable[uint, PendingRequest](),
      responseMap: newTable[string, Future[JsonNode]](),
      projectErrors: @[],
    ),
    cmdLineClientProcessId: params.clientProcessId,
  )

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

    let verbosity = ls.getWorkspaceConfiguration.waitFor.notificationVerbosity.get(
      NlsNotificationVerbosity.nvInfo
    )
    debug "ShowMessage ", message = message
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
  result.extensionCapabilities = ls.extensionCapabilities.toSeq
  var seenPorts = initHashSet[int]()
  for project in ls.projectFiles.values:
    let futNs = project.ns
    if futNs.finished:
      try:
        var ns = futNs.read
        if ns.port in seenPorts:
          continue
        seenPorts.incl(ns.port)
        var nsStatus = NimSuggestStatus(
          projectFile: project.file,
          capabilities: ns.capabilities.toSeq,
          version: ns.version,
          path: ns.nimsuggestPath,
          port: ns.port,
        )
        for open in ns.openFiles:
          nsStatus.openFiles.add open
        result.nimsuggestInstances.add nsStatus
      except CatchableError:
        discard
  for openFile in ls.openFiles.keys:
    let openFilePath = openFile.uriToPath
    result.openFiles.add openFilePath

  result.pendingRequests = ls.pendingRequests.values.toSeq.map(toPendingRequestStatus)
  result.projectErrors = ls.projectErrors

proc sendStatusChanged*(ls: LanguageServer) {.raises: [].} =
  let status = %*ls.getLspStatus()
  if status != ls.lastStatusSent:
    ls.notify("extension/statusUpdate", status)
    ls.lastStatusSent = status

proc addProjectFileToPendingRequest*(
    ls: LanguageServer, id: uint, uri: string
) {.async.} =
  try:
    if id in ls.pendingRequests:
      var projectFile = uri.uriToPath()
      if projectFile notin ls.projectFiles:
        if uri in ls.openFiles:
          projectFile = await ls.openFiles[uri].projectFile

      ls.pendingRequests[id].projectFile = some projectFile
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

  let conf = await ls.getWorkspaceConfiguration
  let maxNimsuggestProcesses = conf.maxNimsuggestProcesses.get(NIM_MAX_NS_PROCESSES)
  # When using only one nimsuggest process, we should not search for parent projects
  # as this will cause all files to be opened in the same nimsuggest process.
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

proc getRootPath*(ip: LspInitializeParams): string =
  if ip.rootUri.isNone or ip.rootUri.get == "":
    if ip.rootPath.isSome and ip.rootPath.get != "":
      return ip.rootPath.get
    else:
      return getCurrentDir().pathToUri.uriToPath

  ip.rootUri.get.uriToPath

proc getRootPath*(ip: McpInitializeParams): string =
  getCurrentDir().pathToUri.uriToPath

proc progressSupported(ls: LanguageServer): bool =
  result = ls.lspInitializeParams.capabilities.window
    .get(ClientCapabilities_window()).workDoneProgress
    .get(false)

proc progress*(ls: LanguageServer, token, kind: string, title = "") =
  if ls.progressSupported:
    ls.notify("$/progress", %*{"token": token, "value": {"kind": kind, "title": title}})

proc workDoneProgressCreate*(ls: LanguageServer, token: string) =
  if ls.progressSupported:
    discard ls.call("window/workDoneProgress/create", %ProgressParams(token: token))

proc cancelPendingFileChecks*(ls: LanguageServer, nimsuggest: Nimsuggest) =
  # stop all checks on file level if we are going to run checks on project
  # level.
  for uri in nimsuggest.openFiles:
    let fileData = ls.openFiles.getOrDefault(uri)
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

  if not ls.getWorkspaceConfiguration.await().autoCheckProject.get(true):
    return
  let conf = await ls.getAndWaitForWorkspaceConfiguration()
  let useNimCheck = conf.useNimCheck.get(USE_NIM_CHECK_BY_DEFAULT)

  let nimPath = getNimPath(conf)

  if useNimCheck and nimPath.isSome:
    proc getFilePath(c: CheckResult): string =
      c.file

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

    # clean files with no diags
    for path in ls.filesWithDiags:
      if not filesWithDiags.contains path:
        debug "Sending zero diags", path = path
        let params =
          PublishDiagnosticsParams %* {"uri": pathToUri(path), "diagnostics": @[]}
        ls.notify("textDocument/publishDiagnostics", %params)
    ls.filesWithDiags = filesWithDiags
    return

  debug "Running diagnostics", uri = uri
  let ns = await ls.tryGetNimSuggest(uri)
  if ns.isNone:
    return
  let nimsuggest = ns.get
  if nimsuggest.checkProjectInProgress:
    debug "Check project is already running", uri = uri
    nimsuggest.needsCheckProject = true
    return

  ls.cancelPendingFileChecks(nimsuggest)

  let token = fmt "Checking {uri}"
  ls.workDoneProgressCreate(token)
  ls.progress(token, "begin", fmt "Checking project {uri.uriToPath}")
  nimsuggest.checkProjectInProgress = true
  defer:
    nimsuggest.checkProjectInProgress = false
    ls.progress(token, "end")

  proc getFilepath(s: Suggest): string =
    s.filepath

  let
    diagnostics = nimsuggest.chk(uriToPath(uri), ls.uriToStash(uri)).await().filter(
        sug => sug.filepath != "???"
      )
    filesWithDiags = diagnostics.map(s => s.filepath).toHashSet

  ls.progress(token, "end")

  debug "Found diagnostics", file = filesWithDiags
  for (path, diags) in groupBy(diagnostics, getFilepath):
    ls.sendDiagnostics(diags, path)

  # clean files with no diags
  for path in ls.filesWithDiags:
    if not filesWithDiags.contains path:
      debug "Sending zero diags", path = path
      let params =
        PublishDiagnosticsParams %* {"uri": pathToUri(path), "diagnostics": @[]}
      ls.notify("textDocument/publishDiagnostics", %params)
  ls.filesWithDiags = filesWithDiags

  if nimsuggest.needsCheckProject:
    nimsuggest.needsCheckProject = false
    callSoon do() {.gcsafe.}:
      debug "Running delayed check project...", uri = uri
      traceAsyncErrors ls.checkProject(uri)

proc removeCompletedPendingRequests(
    ls: LanguageServer, maxTimeAfterRequestWasCompleted = initDuration(seconds = 10)
) =
  var toRemove = newSeq[uint]()
  for id, pr in ls.pendingRequests:
    if pr.state != prsOnGoing:
      let passedTime = now() - pr.endTime
      if passedTime > maxTimeAfterRequestWasCompleted:
        toRemove.add id

  for id in toRemove:
    ls.pendingRequests.del id

proc tick*(ls: LanguageServer): Future[void] {.async.} =
  # debug "Ticking at ", now = now(), prs = ls.pendingRequests.len
  try:
    ls.removeCompletedPendingRequests()
    await ls.removeIdleNimsuggests()
    ls.sendStatusChanged
  except CatchableError as ex:
    error "Error in tick", msg = ex.msg
    writeStacktrace(ex)
