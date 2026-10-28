{.push raises: [], gcsafe.}

import
  std/[
    macros, strformat, os, sugar, hashes, osproc, tables, strutils, sets, uri, json,
    sequtils, setutils, times,
  ],
  with,
  chronos,
  chronos/[threadsync, asyncproc],
  chronicles,
  json_serialization,
  json_rpc/[errors, servers/socketserver],
  regex,
  stew/byteutils,
  ./protocol/[enums, types],
  ./[suggestapi, utils, nimcheck]

export RegexError

proc getVersionFromNimble(): string =
  #We should static run nimble dump instead
  const content = staticRead("nimlangserver.nimble")
  for v in content.splitLines:
    if v.startsWith("version"):
      return v.split("=")[^1].strip(chars = {' ', '"'})
  return "unknown"

const
  RESTART_COMMAND* = "nimlangserver.restart"
  RECOMPILE_COMMAND* = "nimlangserver.recompile"
  CHECK_PROJECT_COMMAND* = "nimlangserver.checkProject"
  FILE_CHECK_DELAY* = 1000
  LSPVersion* = getVersionFromNimble()
  USE_NIM_CHECK_BY_DEFAULT* = false
  NIM_EXPAND_ARC_BY_DEFAULT* = false
  NIM_EXPAND_MACRO_BY_DEFAULT* = false
  NIM_MAX_NS_PROCESSES* = 1
  MaxNimsuggestFails = 10

type
  NlsNimsuggestConfig* = ref object of RootObj
    projectFile*: string
    fileRegex*: string

  NlsWorkingDirectoryMaping* = ref object of RootObj
    projectFile*: string
    directory*: string

  NlsInlayTypeHintsConfig* = ref object of RootObj
    enable*: Option[bool]

  NlsInlayExceptionHintsConfig* = ref object of RootObj
    enable*: Option[bool]
    hintStringLeft*: Option[string]
    hintStringRight*: Option[string]

  NlsInlayParameterHintsConfig* = ref object of RootObj
    enable*: Option[bool]

  NlsInlayHintsConfig* = ref object of RootObj
    typeHints*: Option[NlsInlayTypeHintsConfig]
    exceptionHints*: Option[NlsInlayExceptionHintsConfig]
    parameterHints*: Option[NlsInlayParameterHintsConfig]

  NlsNotificationVerbosity* = enum
    nvNone = "none"
    nvError = "error"
    nvWarning = "warning"
    nvInfo = "info"

  NlsConfig* = ref object of RootObj
    projectMapping*: OptionalSeq[NlsNimsuggestConfig]
    workingDirectoryMapping*: OptionalSeq[NlsWorkingDirectoryMaping]
    checkOnSave*: Option[bool]
    nimsuggestPath*: Option[string]
    timeout*: Option[int]
    autoRestart*: Option[bool]
    autoCheckFile*: Option[bool]
    autoCheckProject*: Option[bool]
    logNimsuggest*: Option[bool]
    inlayHints*: Option[NlsInlayHintsConfig]
    notificationVerbosity*: Option[NlsNotificationVerbosity]
    formatOnSave*: Option[bool]
    nimsuggestIdleTimeout*: Option[int] #idle timeout in ms
    useNimCheck*: Option[bool]
    nimExpandArc*: Option[bool]
    nimExpandMacro*: Option[bool]
    maxNimsuggestProcesses*: Option[int]
      #max number of nimsuggest processes to keep alive. zero means unlimited
    nimsuggestTimeout*: Option[int]
      #timeout for the nimsuggest startup + initial compilation
    nimsuggestMaxMemory*: Option[int]
      #memory cap per nimsuggest process in MB. zero means unlimited
    useNimTrack*: Option[bool]

  NlsFileInfo* = ref object of RootObj
    projectFile*: Future[string].Raising([CancelledError, OSError, RegexError])
    changed*: bool
    fingerTable*: seq[seq[tuple[u16pos, offset: int]]]
    fileCheck*: Future[void].Raising(
      [
        CancelledError, AsyncProcessError, AsyncStreamError, OSError, IOError,
        RegexError, NimsuggestError,
      ]
    )
    edits*: uint
    textDocument*: TextDocumentItem
    nimsuggestProject*: string

  CommandLineParams* = object
    mode*: Option[ServerMode]
    transport*: Option[TransportMode]
    port*: Port #only for sockets

  ServerMode* = enum
    lsp = "lsp"
    mcp = "mcp"

  TransportMode* = enum
    stdio = "stdio"
    socket = "socket"

  PendingRequestState* = enum
    prsOnGoing = "OnGoing"
    prsCancelled = "Cancelled"
    prsComplete = "Complete"

  PendingRequest* = object
    id*: uint
    name*: string
    request*: FutureBase
    projectFile*: Option[string]
    startTime*: DateTime
    endTime*: DateTime
    state*: PendingRequestState

  LanguageServer* = ref object
    case serverMode*: ServerMode
    of lsp:
      lspClientCapabilities*: LspClientCapabilities
      lspServerCapabilities*: LspServerCapabilities
      lspInitializeParams*: LspInitializeParams
    of mcp:
      mcpClientCapabilities*: McpClientCapabilities
      mcpServerCapabilities*: McpServerCapabilities
      mcpInitializeParams*: McpInitializeParams
    extensionCapabilities*: set[LspExtensionCapability]
    notifyAction*: NotifyAction
    callAction*: CallAction
    onExit*: OnExitCallback
    projectFiles*: Table[string, Project]
    nimsuggestCreations*: Table[string, Future[void].Raising([CancelledError])]
    openFiles*: Table[string, NlsFileInfo]
    workspaceConfiguration*: NlsConfig
      #What the client configured us with, or the defaults until it does.
      #Set through setWorkspaceConfiguration, read through workspaceConfigurationWait.
    workspaceConfigurationReady*: Future[void].Raising([CancelledError])
      #Completed the first time a configuration is known, and never replaced.
    inlayHintsRefreshRequest*: Future[JsonNode].Raising([CancelledError, JsonRpcError])
    watchingFiles*: bool
    filesWithDiags*: HashSet[string]
    lastNimsuggest*: Nimsuggest
    nimsuggestShutdown: Future[void].Raising([])
    initialized*: bool
      #Set once initialize has run. Until then routes can't rely on its state.
    isShutdown*: bool
    storageDir*: string
    nimblePackages*: Table[string, NimblePackage] #nimble file to its package
    nimblePackageLoads*: Table[string, Future[void].Raising([CancelledError])]
    testRunProcess*: Option[AsyncProcessRef]
      #There is only one test run process at a time
    srv*: RpcServer #Both modes use it to store the routes
    pendingRequests*: Table[uint, PendingRequest]
      #id to future. Each request is added here so we can cancel them later in the cancelRequest. Only requests, not notifications
    transportMode*: TransportMode
    served*: Future[void]
    projectErrors*: seq[ProjectError]
    lastStatusSent: JsonString
    failTable*: Table[string, int]
      #Project file to fail count
      #List of errors (crashes) nimsuggest has had since the lsp session started
    checkInProgress*: bool
    token: uint

  Certainty* = enum
    None
    Folder
    Cfg

  NimblePackage* = object
    dir*: string
    sourceDir*: string
    nimDir*: Option[string]
    projectFile*: string
    entryPoints*: seq[string]
    dumpFailed*: bool
    nimbleFileTime: Time #when the dump started

  OnExitCallback* = proc(): Future[void] {.async: (raises: []).}
    #To be called when the server is shutting down
  NotifyAction* =
    proc(name: string, params: JsonString): Future[void] {.async: (raises: []).}
    #Send a notification to the client
  CallAction* = proc(name: string, params: JsonString): Future[JsonNode] {.
    async: (raises: [CancelledError, JsonRpcError])
  .} #Send a request to the client

macro `%*`*(t: untyped, inputStream: untyped): untyped =
  ## Typed JSON literal: `T %* {...}`. The literal is written in code, so a
  ## failing conversion is a programming error, not something to handle.
  let conv =
    newCall(bindSym("to", brOpen), newCall(bindSym("%*", brOpen), inputStream), t)
  result = quote:
    try:
      `conv`
    except ValueError:
      raiseAssert getCurrentExceptionMsg()

proc notify*[T](ls: LanguageServer, name: string, params: T) =
  asyncSpawn ls.notifyAction(name, JsonString LspJson.encode(params))

proc call*[T](
    ls: LanguageServer, name: string, params: T
): Future[JsonNode] {.async: (raw: true, raises: [CancelledError, JsonRpcError]).} =
  ls.callAction(name, JsonString LspJson.encode(params))

proc initLs*(params: CommandLineParams, storageDir: string): LanguageServer =
  LanguageServer(
    workspaceConfiguration: NlsConfig(),
    workspaceConfigurationReady: Future[void].Raising([CancelledError]).init("initLs"),
    filesWithDiags: initHashSet[string](),
    serverMode: params.mode.get(),
    transportMode: params.transport.get(stdio),
    openFiles: initTable[string, NlsFileInfo](),
    storageDir: storageDir,
    extensionCapabilities: LspExtensionCapability.items.toSet,
  )

proc createProgressToken*(ls: LanguageServer): string =
  inc ls.token
  "token-" & $ls.token

proc isShutdownNimsuggest*(ls: LanguageServer): bool =
  ls.nimsuggestShutdown != nil

func typeHintsEnabled*(cnf: NlsConfig): bool =
  result = true
  if cnf.inlayHints.isSome and cnf.inlayHints.get.typeHints.isSome and
      cnf.inlayHints.get.typeHints.get.enable.isSome:
    result = cnf.inlayHints.get.typeHints.get.enable.get

func exceptionHintsEnabled*(cnf: NlsConfig): bool =
  result = false
  if cnf.inlayHints.isSome and cnf.inlayHints.get.exceptionHints.isSome and
      cnf.inlayHints.get.exceptionHints.get.enable.isSome:
    result = cnf.inlayHints.get.exceptionHints.get.enable.get

func parameterHintsEnabled*(cnf: NlsConfig): bool =
  result = true
  if cnf.inlayHints.isSome and cnf.inlayHints.get.parameterHints.isSome and
      cnf.inlayHints.get.parameterHints.get.enable.isSome:
    result = cnf.inlayHints.get.parameterHints.get.enable.get

func inlayHintsEnabled*(cnf: NlsConfig): bool =
  typeHintsEnabled(cnf) or exceptionHintsEnabled(cnf) or parameterHintsEnabled(cnf)

proc supportSignatureHelp*(cc: LspClientCapabilities): bool =
  if cc.isNil:
    return false
  let caps = cc.textDocument
  caps.isSome and caps.get.signatureHelp.isSome

proc parseWorkspaceConfiguration*(conf: JsonNode): NlsConfig =
  try:
    if conf.kind == JObject and conf["settings"].kind == JObject:
      let nimSettings = conf["settings"]["nim"]
      if nimSettings.kind == JNull:
        return NlsConfig() #the client has no settings for us
      return nimSettings.to(NlsConfig)
  except ValueError:
    discard
  try:
    let nlsConfig: seq[NlsConfig] = (%conf).to(seq[NlsConfig])
    result =
      if nlsConfig.len > 0 and nlsConfig[0] != nil:
        nlsConfig[0]
      else:
        NlsConfig()
  except ValueError:
    debug "Failed to parse the configuration.", error = getCurrentExceptionMsg()
    result = NlsConfig()

proc setWorkspaceConfiguration*(ls: LanguageServer, conf: JsonNode) {.raises: [].} =
  ls.workspaceConfiguration = parseWorkspaceConfiguration(conf)
  if not ls.workspaceConfigurationReady.finished:
    ls.workspaceConfigurationReady.complete()

proc workspaceConfigurationWait*(
    ls: LanguageServer
): Future[NlsConfig] {.async: (raises: [CancelledError]).} =
  if ls.workspaceConfigurationReady.finished():
    ls.workspaceConfiguration
  else:
    # only ever wait 10s for everyone
    if not await chronos.withTimeout(
      ls.workspaceConfigurationReady.join(), chronos.seconds(10)
    ):
      if not ls.workspaceConfigurationReady.finished():
        debug "Workspace config ready timeout; setting default config"
        ls.setWorkspaceConfiguration(newJArray())
    ls.workspaceConfiguration

proc showMessage*(
    ls: LanguageServer, message: string, typ: MessageType
) {.async: (raises: [CancelledError]).} =
  proc notify() =
    ls.notify(
      "window/showMessage", ShowMessageParams(`type`: typ.int, message: message)
    )

  let conf = await ls.workspaceConfigurationWait()
  let verbosity = conf.notificationVerbosity.get(NlsNotificationVerbosity.nvInfo)
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

proc applyEdit*(
    ls: LanguageServer, params: ApplyWorkspaceEditParams
): Future[ApplyWorkspaceEditResponse] {.
    async: (raises: [CancelledError, ValueError, JsonRpcError])
.} =
  let res = await ls.call("workspace/applyEdit", params)
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

# https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#responseMessage
proc checkInitialized*(ls: LanguageServer) {.raises: [ApplicationError].} =
  if not ls.initialized:
    raise (ref ApplicationError)(
      code: ErrorCode.ServerNotInitialized.int, msg: "Server not initialized"
    )

proc filesServedBy(ls: LanguageServer, projectFile: string): seq[string] =
  for uri, file in ls.openFiles:
    if file.nimsuggestProject == projectFile:
      result.add uri

proc getLspStatus*(ls: LanguageServer): NimLangServerStatus {.raises: [].} =
  result.lspPath = getAppFilename()
  result.version = LSPVersion
  result.extensionCapabilities = ls.extensionCapabilities.toSeq
  for project in ls.projectFiles.values:
    let ns = project.ns
    if ns != nil:
      var nsStatus = NimsuggestStatus(
        projectFile: project.file,
        capabilities: ns.capabilities.toSeq,
        version: ns.version,
        path: ns.nimsuggestPath,
        port: ns.port,
      )
      nsStatus.openFiles = ls.filesServedBy(project.file)
      result.nimsuggestInstances.add nsStatus
  for openFile in ls.openFiles.keys:
    let openFilePath = openFile.uriToPath
    result.openFiles.add openFilePath

  result.pendingRequests = ls.pendingRequests.values.toSeq.map(toPendingRequestStatus)
  result.projectErrors = ls.projectErrors

proc sendStatusChanged*(ls: LanguageServer) {.raises: [].} =
  let status = JsonString LspJson.encode(ls.getLspStatus())
  if status != ls.lastStatusSent:
    ls.notify("extension/statusUpdate", status)
    ls.lastStatusSent = status

proc waitProjectFile*(
    file: NlsFileInfo
): Future[string] {.async: (raises: [CancelledError, OSError, RegexError]).} =
  ## Wait without allowing a cancelled request to cancel the shared future.
  ## A configuration change replaces the future, so wait for the current one.
  while not file.projectFile.finished:
    await file.projectFile.join()
  try:
    file.projectFile.read()
  except FuturePendingError:
    raiseAssert "project file future remained pending after join"

proc addProjectFileToPendingRequest*(
    ls: LanguageServer, id: uint, uri: string
) {.async: (raises: []).} =
  try:
    if id in ls.pendingRequests:
      var projectFile = uri.uriToPath()
      if projectFile notin ls.projectFiles:
        if uri in ls.openFiles:
          projectFile = await ls.openFiles[uri].waitProjectFile()

      ls.pendingRequests[id].projectFile = some projectFile
      ls.sendStatusChanged
  except CancelledError:
    discard
  except KeyError, OSError, RegexError:
    error "addProjectFileToPendingRequest failed",
      uri = uri, msg = getCurrentExceptionMsg()

proc requiresDynamicRegistrationForDidChangeConfiguration(ls: LanguageServer): bool =
  ls.lspClientCapabilities.workspace.isSome and
    ls.lspClientCapabilities.workspace.get.didChangeConfiguration.isSome and
    ls.lspClientCapabilities.workspace.get.didChangeConfiguration.get.dynamicRegistration.get(
      false
    )

proc supportsDynamicRegistrationForDidChangeWatchedFiles(ls: LanguageServer): bool =
  ls.lspClientCapabilities.workspace.isSome and
    ls.lspClientCapabilities.workspace.get.didChangeWatchedFiles.isSome and
    ls.lspClientCapabilities.workspace.get.didChangeWatchedFiles.get.dynamicRegistration.get(
      false
    )

proc supportsConfigurationRequest(ls: LanguageServer): bool =
  ls.lspClientCapabilities.workspace.isSome and
    ls.lspClientCapabilities.workspace.get.configuration.get(false)

proc usePullConfigurationModel*(ls: LanguageServer): bool =
  ls.requiresDynamicRegistrationForDidChangeConfiguration and
    ls.supportsConfigurationRequest

proc getNimVersion(nimDir: string): string {.raises: [OSError, IOError].} =
  let cmd =
    if nimDir == "":
      "nim --version"
    else:
      nimDir / "nim --version"
  let info = execProcess(cmd)
  const NimCompilerVersion = "Nim Compiler Version "
  for line in info.splitLines:
    if line.startsWith(NimCompilerVersion):
      return line

proc getRootPath*(ip: LspInitializeParams): string {.raises: [OSError].} =
  if ip.rootUri.isNone or ip.rootUri.get == "":
    if ip.rootPath.isSome and ip.rootPath.get != "":
      return ip.rootPath.get
    else:
      return getCurrentDir().pathToUri.uriToPath

  ip.rootUri.get.uriToPath

proc getRootPath*(ip: McpInitializeParams): string {.raises: [OSError].} =
  getCurrentDir().pathToUri.uriToPath

proc getRootPath(ls: LanguageServer): string {.raises: [OSError].} =
  case ls.serverMode
  of mcp:
    ls.mcpInitializeParams.getRootPath()
  of lsp:
    ls.lspInitializeParams.getRootPath()

proc packageNimbleFile(ls: LanguageServer, file: string): string {.raises: [OSError].} =
  let rootPath = ls.getRootPath()
  let inRoot = file.isRelTo(rootPath)
  if inRoot:
    for nimbleFile in ls.nimblePackageLoads.keys:
      if nimbleFile.isRelTo(rootPath) and file.isRelTo(nimbleFile.parentDir):
        return nimbleFile
  var dir = file.parentDir
  while true:
    let nimbleFiles = walkFiles(dir / "*.nimble").toSeq
    if nimbleFiles.len == 1:
      result = nimbleFiles[0]
      if not inRoot:
        return
    elif nimbleFiles.len > 1:
      debug "Ignoring a folder with several nimble files", dir = dir
    let parent = dir.parentDir
    if parent.len == 0 or parent == dir or (inRoot and not parent.isRelTo(rootPath)):
      return
    dir = parent

proc loadNimblePackage(
    ls: LanguageServer, nimbleFile: string
) {.async: (raises: [CancelledError]).} =
  let packageDir = nimbleFile.parentDir
  var
    package = NimblePackage(dir: packageDir)
    name, srcDir: string
    entryPoints: seq[string]
    exitCode = -1
  debug "nimble dump starting",
    nimbleFile = nimbleFile, nimbleDir = getEnv("NIMBLE_DIR")
  var process: AsyncProcessRef
  try:
    package.nimbleFileTime = getLastModificationTime(nimbleFile)
    process = await startProcess(
      "nimble",
      workingDir = packageDir,
      arguments = @["dump"],
      options = {UsePath},
      stderrHandle = ProcessStreamHandle(), # None => chronos doesn't
      # manage stderr, child inherits ours
      stdoutHandle = AsyncProcess.Pipe,
    )
    let info = string.fromBytes(process.stdoutStream.read().await)

    for line in info.splitLines:
      if line.startsWith("srcDir"):
        srcDir = line[(1 + line.find '"') ..^ 2]
      if line.startsWith("name"):
        name = line[(1 + line.find '"') ..^ 2]
      if line.startsWith("nimDir"):
        package.nimDir = some line[(1 + line.find '"') ..^ 2]
      if line.startsWith("entryPoints"):
        entryPoints =
          line[(1 + line.find '"') ..^ 2].split(',').mapIt(it.strip(chars = {' ', '"'}))
    exitCode = await process.waitForExit()

    debug "nimble dump finished",
      nimbleFile = nimbleFile, exitCode = exitCode, nimDir = package.nimDir.get("")
  except OSError, IOError, AsyncProcessError, AsyncStreamError:
    debug "Failed to get nimble dump info",
      nimbleFile = nimbleFile, err = getCurrentExceptionMsg()
  finally:
    if process != nil:
      await shutdownChildProcess(process)

  if exitCode != 0:
    warn "nimble dump failed", nimbleFile = nimbleFile, exitCode = exitCode
    package.dumpFailed = true
  package.sourceDir = packageDir / srcDir
  package.entryPoints = entryPoints.mapIt(packageDir / it).filterIt(it.fileExists)
  let projectFile = package.sourceDir / (name & ".nim")
  if name.len > 0 and fileExists(projectFile):
    package.projectFile = projectFile
    if projectFile notin package.entryPoints:
      package.entryPoints.add projectFile
  ls.nimblePackages[nimbleFile] = package

proc isFailedDumpOutdated(
    ls: LanguageServer, nimbleFile: string
): bool {.raises: [OSError].} =
  let package = ls.nimblePackages.getOrDefault(nimbleFile)
  package.dumpFailed and getLastModificationTime(nimbleFile) != package.nimbleFileTime

proc nimblePackage(
    ls: LanguageServer, file: string
): Future[NimblePackage] {.async: (raises: [CancelledError, OSError]).} =
  if ls.isShutdownNimsuggest:
    debug "Not running nimble dump, the server is shutting down", file = file
    return NimblePackage()
  let nimbleFile = ls.packageNimbleFile(file)
  if nimbleFile.len == 0:
    return NimblePackage()
  if ls.isFailedDumpOutdated(nimbleFile):
    ls.nimblePackages.del(nimbleFile)
    ls.nimblePackageLoads.del(nimbleFile)
  if nimbleFile notin ls.nimblePackageLoads:
    ls.nimblePackageLoads[nimbleFile] = ls.loadNimblePackage(nimbleFile)
  await ls.nimblePackageLoads.getOrDefault(nimbleFile).join()
  ls.nimblePackages.getOrDefault(nimbleFile)

proc getNimsuggestPathAndVersion(
    ls: LanguageServer, conf: NlsConfig, file: string
): Future[(string, string)] {.async: (raises: [CancelledError, OSError, IOError]).} =
  var nimsuggestPath = expandTilde(conf.nimsuggestPath.get(""))
  var nimVersion = ""
  if nimsuggestPath == "":
    let package = await ls.nimblePackage(file)
    let nimDir = package.nimDir.get ""
    if nimDir != "" and nimDir.dirExists:
      nimVersion = getNimVersion(nimDir) & " from " & nimDir
      nimsuggestPath = nimDir / "nimsuggest".addFileExt(ExeExt)
    else:
      nimVersion = getNimVersion("")
      nimsuggestPath = findExe "nimsuggest"
  else:
    nimVersion = getNimVersion(nimsuggestPath.parentDir)
  # await ls.showMessage(fmt "Using {nimVersion}", MessageType.Info)
  debug "Using {nimVersion}", nimVersion = nimVersion
  (nimsuggestPath, nimVersion)

proc getNimPath*(
    ls: LanguageServer, conf: NlsConfig, file: string
): Future[Option[string]] {.async: (raises: [CancelledError, OSError, IOError]).} =
  if conf.nimsuggestPath.isSome and conf.nimsuggestPath.get().fileExists():
    some(conf.nimsuggestPath.get.parentDir / "nim".addFileExt(ExeExt))
  else:
    let (nimsuggestPath, _) = await ls.getNimsuggestPathAndVersion(conf, file)
    let path =
      if nimsuggestPath.fileExists():
        nimsuggestPath.parentDir / "nim".addFileExt(ExeExt)
      else:
        findExe "nim"

    if path != "":
      some(path)
    else:
      warn "Failed to find nim path"
      none(string)

proc getProjectFileAutoGuess*(
    ls: LanguageServer, fileUri: string
): Future[string] {.async: (raises: [CancelledError, OSError]).} =
  let file = fileUri.decodeUrl
  debug "Auto-guessing project file for", file = file
  result = file
  let (dir, _, _) = result.splitFile()
  var
    path = dir
    certainty = Certainty.None
    up = 0

  let conf = await ls.workspaceConfigurationWait()
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
    if path == dir:
      break
    path = dir
    inc up

proc getWorkingDir*(
    ls: LanguageServer, path: string
): Future[string] {.async: (raises: [CancelledError, OSError]).} =
  let
    rootPath = ls.getRootPath()
    pathRelativeToRoot = path.tryRelativeTo(rootPath)
    conf = await ls.workspaceConfigurationWait()
    mapping = conf.workingDirectoryMapping.get(@[])

  for m in mapping:
    if pathRelativeToRoot.isSome and m.projectFile == pathRelativeToRoot.get():
      return rootPath / m.directory

  let package = await ls.nimblePackage(path)
  if package.dir.len > 0: package.dir else: rootPath

proc progressSupported(ls: LanguageServer): bool =
  ls.serverMode == lsp and
    ls.lspInitializeParams.capabilities.window
    .get(ClientCapabilities_window()).workDoneProgress
    .get(false)

proc progress*(ls: LanguageServer, token, kind: string, title = "") =
  if ls.progressSupported:
    ls.notify(
      "$/progress",
      ProgressParams(token: token, value: some %*{"kind": kind, "title": title}),
    )

proc workDoneProgressCreate*(ls: LanguageServer, token: string) =
  if ls.progressSupported:
    discard ls.call("window/workDoneProgress/create", ProgressParams(token: token))

proc cancelPendingFileChecks*(ls: LanguageServer, nimsuggest: Nimsuggest) =
  # stop all checks on file level if we are going to run checks on project
  # level.
  for uri in ls.filesServedBy(nimsuggest.project.file):
    let info = ls.openFiles.getOrDefault(uri)
    if info != nil and info.fileCheck != nil and not info.fileCheck.finished():
      info.fileCheck.cancelSoon()

proc uriStorageLocation*(ls: LanguageServer, uri: string): string =
  ls.storageDir / (hash(uri).toHex & ".nim")

proc uriToStash*(ls: LanguageServer, uri: string): string =
  let file = ls.openFiles.getOrDefault(uri)
  if file != nil and file.changed:
    uriStorageLocation(ls, uri)
  else:
    ""

proc toUtf16Pos*(
    ls: LanguageServer, uri: string, line: int, utf8Pos: int
): Option[int] =
  let file = ls.openFiles.getOrDefault(uri)
  if file != nil and line in 0 ..< file.fingerTable.len:
    let utf16Pos = file.fingerTable[line].utf8to16(utf8Pos)
    return some(utf16Pos)
  else:
    return none(int)

proc toUtf16Pos*(suggest: Suggest, ls: LanguageServer): Suggest =
  result = suggest
  let uri = pathToUri(suggest.filePath)
  let pos = toUtf16Pos(ls, uri, suggest.line - 1, suggest.column)
  if pos.isSome:
    result.column = pos.get()

proc toUtf16Pos*(
    suggest: SuggestInlayHint, ls: LanguageServer, uri: string
): SuggestInlayHint =
  result = suggest
  let pos = toUtf16Pos(ls, uri, suggest.line - 1, suggest.column)
  if pos.isSome:
    result.column = pos.get()

proc toUtf16Pos*(checkResult: CheckResult, ls: LanguageServer): CheckResult =
  result = checkResult
  let uri = pathToUri(checkResult.file)
  let pos = toUtf16Pos(ls, uri, checkResult.line - 1, checkResult.column)
  if pos.isSome:
    result.column = pos.get()

  for i in 0 ..< result.stacktrace.len:
    let stPos =
      toUtf16Pos(ls, uri, result.stacktrace[i].line - 1, result.stacktrace[i].column)
    if stPos.isSome:
      result.stacktrace[i].column = stPos.get()

proc range*(startLine, startCharacter, endLine, endCharacter: int): Range =
  return
    Range %* {
      "start": {"line": startLine, "character": startCharacter},
      "end": {"line": endLine, "character": endCharacter},
    }

proc toLabelRange*(suggest: Suggest): Range =
  with suggest:
    return range(line - 1, column, line - 1, column + utf16Len(qualifiedPath[^1]))

proc toDiagnostic(suggest: Suggest): Diagnostic =
  with suggest:
    let
      textStart = doc.find('\'')
      textEnd = doc.rfind('\'')
      endColumn =
        if textStart >= 0 and textEnd > textStart:
          column + utf16Len(doc[textStart + 1 ..< textEnd])
        else:
          column + 1

    return
      Diagnostic %* {
        "uri": pathToUri(filePath),
        "range": range(line - 1, column, line - 1, endColumn),
        "severity":
          case forth
          of "Error": DiagnosticSeverity.Error.int
          of "Hint": DiagnosticSeverity.Hint.int
          of "Warning": DiagnosticSeverity.Warning.int
          else: DiagnosticSeverity.Error.int
        ,
        "message": doc,
        "source": "nim",
        "code": "nimsuggest chk",
      }

proc toDiagnostic(checkResult: CheckResult): Diagnostic =
  let
    textStart = checkResult.msg.find('\'')
    textEnd = checkResult.msg.rfind('\'')
    endColumn =
      if textStart >= 0 and textEnd >= 0 and textEnd > textStart:
        checkResult.column + utf16Len(checkResult.msg[textStart + 1 ..< textEnd])
      else:
        checkResult.column + 1

  return
    Diagnostic %* {
      "uri": pathToUri(checkResult.file),
      "range": range(
        checkResult.line - 1,
        max(0, checkResult.column),
        checkResult.line - 1,
        max(0, endColumn),
      ),
      "severity":
        case checkResult.severity
        of "Error": DiagnosticSeverity.Error.int
        of "Hint": DiagnosticSeverity.Hint.int
        of "Warning": DiagnosticSeverity.Warning.int
        else: DiagnosticSeverity.Error.int
      ,
      "message": checkResult.msg,
      "source": "nim",
      "code": "nim check",
    }

proc sendDiagnostics*(
    ls: LanguageServer, diagnostics: seq[Suggest] | seq[CheckResult], path: string
) =
  trace "Sending diagnostics", count = diagnostics.len, path = path
  let params =
    PublishDiagnosticsParams %* {
      "uri": pathToUri(path),
      "diagnostics": diagnostics.map(x => x.toUtf16Pos(ls).toDiagnostic),
    }
  ls.notify("textDocument/publishDiagnostics", params)
  if diagnostics.len != 0:
    ls.filesWithDiags.incl path
  else:
    ls.filesWithDiags.excl path

proc createOrRestartNimsuggest*(
  ls: LanguageServer, projectFile: string, uri = ""
): Future[void] {.async: (raw: true, raises: [CancelledError]).}

proc isLiveNimsuggestProject(ls: LanguageServer, projectFile: string): bool =
  projectFile in ls.projectFiles or projectFile in ls.nimsuggestCreations

proc entryPoints*(ls: LanguageServer): seq[string] =
  for package in ls.nimblePackages.values:
    result.add package.entryPoints

proc liveNimsuggestProjects*(ls: LanguageServer): seq[string] =
  ## Running + starting instances.
  result = ls.projectFiles.keys.toSeq
  for projectFile in ls.nimsuggestCreations.keys:
    if projectFile notin result:
      result.add projectFile

proc canSpawnNimsuggest(ls: LanguageServer, conf: NlsConfig): bool =
  let nsCount = ls.liveNimsuggestProjects.len
  let maxNimsuggestProcesses = conf.maxNimsuggestProcesses.get(NIM_MAX_NS_PROCESSES)
  result = maxNimsuggestProcesses == 0 or nsCount < maxNimsuggestProcesses
  debug "canSpawnNimsuggest",
    result = result, nsCount = nsCount, maxNimsuggestProcesses = maxNimsuggestProcesses

proc reuseLiveNimsuggestProject(
    ls: LanguageServer, projectFile: string, package: NimblePackage
): string =
  let live = ls.liveNimsuggestProjects
  let own = package.entryPoints.filterIt(it in live)
  result =
    if projectFile in live:
      projectFile
    elif own.len > 0:
      own[^1]
    elif live.len > 0:
      live[0]
    else:
      ""
  if result != projectFile:
    debug "Reached the maximum instances of nimsuggest, reusing a nimsuggest instance",
      projectFile = projectFile, project = result

proc mappedProjectFiles(
    ls: LanguageServer, conf: NlsConfig
): seq[string] {.raises: [OSError].} =
  conf.projectMapping.get(@[]).mapIt(ls.getRootPath() / it.projectFile)

proc nimsuggestProjectFor(
    ls: LanguageServer, uri: string
): Future[string] {.async: (raises: [CancelledError, OSError, RegexError]).} =
  let file = ls.openFiles.getOrDefault(uri)
  if file == nil:
    return ""
  let conf = await ls.workspaceConfigurationWait()
  let projectFile = await file.waitProjectFile()
  if ls.canSpawnNimsuggest(conf):
    projectFile
  else:
    let package = await ls.nimblePackage(uri.uriToPath)
    ls.reuseLiveNimsuggestProject(projectFile, package)

proc failoverProject(ls: LanguageServer, projectFile: string): string =
  if ls.failTable.getOrDefault(projectFile, 0) < MaxNimsuggestFails:
    projectFile
  else:
    let others = ls.projectFiles.keys.toSeq.filterIt(
      it != projectFile and ls.failTable.getOrDefault(it, 0) < MaxNimsuggestFails
    )
    if others.len > 0:
      others[0]
    else:
      ""

proc hasServingNimsuggest(ls: LanguageServer, file: NlsFileInfo): bool =
  file.nimsuggestProject != "" and ls.isLiveNimsuggestProject(file.nimsuggestProject) and
    ls.failTable.getOrDefault(file.nimsuggestProject, 0) < MaxNimsuggestFails

proc getNimsuggestInner(
    ls: LanguageServer, uri: string
): Future[Nimsuggest] {.async: (raises: [CancelledError, OSError, RegexError]).} =
  let file = ls.openFiles.getOrDefault(uri)
  if file == nil:
    debug "File is no longer open", uri = uri
    return nil

  if not ls.hasServingNimsuggest(file):
    let ownProject = await ls.nimsuggestProjectFor(uri)
    file.nimsuggestProject = ls.failoverProject(ownProject)
    if file.nimsuggestProject notin ["", ownProject]:
      debug "Reusing nimsuggest instance for",
        uri = uri, projectFile = file.nimsuggestProject
  let nsProject = file.nimsuggestProject
  if nsProject == "":
    return nil
  if not ls.projectFiles.hasKey(nsProject):
    debug "Creating new nimsuggest instance", uri = uri, projectFile = nsProject
    await ls.createOrRestartNimsuggest(nsProject, uri)
    # Wait a bit to allow nimsuggest to start
    await sleepAsync(10)

  # Check multiple times with small delays
  var attempts = 0
  const maxAttempts = 10
  while attempts < maxAttempts:
    let project = ls.projectFiles.getOrDefault(nsProject)
    if project != nil:
      ls.lastNimsuggest = project.ns
      return project.ns

    inc attempts
    if attempts < maxAttempts:
      await sleepAsync(100)
      debug "Waiting for nimsuggest to initialize",
        uri = uri, projectFile = nsProject, attempt = attempts

  debug "Failed to get nimsuggest after waiting", uri = uri, projectFile = nsProject
  return nil

proc tryGetNimsuggest*(
  ls: LanguageServer, uri: string
): Future[Option[Nimsuggest]] {.
  async: (raises: [CancelledError, OSError, IOError, RegexError])
.}

proc checkFile*(
  ls: LanguageServer, file: NlsFileInfo
): Future[void] {.
  async: (
    raises: [
      CancelledError, AsyncProcessError, AsyncStreamError, OSError, IOError, RegexError,
      NimsuggestError,
    ]
  )
.}

proc didCloseFile*(
    ls: LanguageServer, uri: string
): Future[void] {.async: (raises: []).} =
  debug "Closed the following document:", uri = uri

  let file = ls.openFiles.getOrDefault(uri)
  ls.openFiles.del uri

  if file != nil and file.changed:
    # check the file if it is closed but not saved.
    traceAsyncErrors ls.checkFile(file)

proc getProjectFile*(
  ls: LanguageServer, uri: string
): Future[string] {.async: (raises: [CancelledError, OSError, RegexError]).}

proc didOpenFile*(
    ls: LanguageServer, textDocument: TextDocumentItem
): Future[void] {.async: (raises: [CancelledError, OSError, IOError, RegexError]).} =
  with textDocument:
    debug "New document opened for URI:", uri = uri
    let file = open(ls.uriStorageLocation(uri), fmWrite)
    let projectFileFuture = ls.getProjectFile(uriToPath(uri))
    let openFile = NlsFileInfo(
      projectFile: projectFileFuture,
      changed: false,
      fingerTable: @[],
      textDocument: textDocument,
    )
    ls.openFiles[uri] = openFile

    try:
      for line in text.splitLines:
        openFile.fingerTable.add line.createUTFMapping()
        file.writeLine line
    finally:
      file.close()

    let projectFile = await openFile.waitProjectFile()
    debug "Document associated with the following projectFile",
      uri = uri, projectFile = projectFile
    # start ns on open file for chk diagnostics
    discard await ls.tryGetNimsuggest(uri)
    let projectFileUri = projectFile.pathToUri
    if projectFileUri notin ls.openFiles:
      var textDocument = TextDocumentItem(
        uri: projectFileUri, languageId: "nim", version: 0, text: readFile(projectFile)
      )

      await didOpenFile(ls, textDocument)

      debug "Opening project file", uri = projectFile, file = uri
    await ls.showMessage(fmt "Opening {uri}", MessageType.Info)

proc checkNimsuggestProject(
    ls: LanguageServer, uri: string, nimsuggest: Nimsuggest
): Future[void] {.
    async: (
      raises: [
        CancelledError, AsyncProcessError, AsyncStreamError, OSError, IOError,
        RegexError, NimsuggestError,
      ]
    )
.} =
  if nimsuggest.checkProjectInProgress:
    debug "Check project is already running", uri = uri
    nimsuggest.needsCheckProject = true
    return

  ls.cancelPendingFileChecks(nimsuggest)

  let token = ls.createProgressToken()
  ls.workDoneProgressCreate(token)
  ls.progress(token, "begin", fmt "Checking project {uri.uriToPath}")
  nimsuggest.checkProjectInProgress = true
  defer:
    nimsuggest.checkProjectInProgress = false
    ls.progress(token, "end")

  proc getFilepath(s: Suggest): string =
    s.filePath

  nimsuggest.stale = false
  let
    diagnostics = nimsuggest.chk(uriToPath(uri), ls.uriToStash(uri)).await().filter(
        sug => sug.filePath != "???"
      )
    filesWithDiags = diagnostics.map(s => s.filePath).toHashSet

  debug "Found diagnostics", file = filesWithDiags
  for (path, diags) in groupBy(diagnostics, getFilepath):
    ls.sendDiagnostics(diags, path)

  # clean files with no diags
  for path in ls.filesWithDiags:
    if not filesWithDiags.contains path:
      debug "Sending zero diags", path = path
      let params =
        PublishDiagnosticsParams %* {"uri": pathToUri(path), "diagnostics": @[]}
      ls.notify("textDocument/publishDiagnostics", params)
  ls.filesWithDiags = filesWithDiags

  if nimsuggest.needsCheckProject:
    nimsuggest.needsCheckProject = false
    callSoon do(data: pointer) {.gcsafe.}:
      debug "Running delayed check project...", uri = uri
      traceAsyncErrors ls.checkNimsuggestProject(uri, nimsuggest)

proc tryGetNimsuggest*(
    ls: LanguageServer, uri: string
): Future[Option[Nimsuggest]] {.
    async: (raises: [CancelledError, OSError, IOError, RegexError])
.} =
  if uri notin ls.openFiles:
    return none(Nimsuggest)

  var retryCount = 0
  const maxRetries = 3
  while retryCount < maxRetries:
    let ns = await getNimsuggestInner(ls, uri)
    if not ns.isNil:
      if ns.stale and not ns.checkProjectInProgress:
        ns.stale = false
        traceAsyncErrors ls.checkNimsuggestProject(uri, ns)
      return some ns

    let file = ls.openFiles.getOrDefault(uri)
    if file == nil or file.nimsuggestProject == "":
      break

    # If nimsuggest is nil, wait a bit and retry
    inc retryCount
    if retryCount < maxRetries:
      debug "Nimsuggest not ready, retrying...", uri = uri, attempt = retryCount
      await sleepAsync(10000 * retryCount) # Exponential backoff

  debug "Nimsuggest not found after retries", uri = uri
  return none(Nimsuggest)

proc checkProject*(
    ls: LanguageServer, uri: string
): Future[void] {.
    async: (
      raises: [
        CancelledError, AsyncProcessError, AsyncStreamError, OSError, IOError,
        RegexError, NimsuggestError,
      ]
    )
.} =
  if ls.checkInProgress:
    return
  ls.checkInProgress = true
  defer:
    ls.checkInProgress = false

  let conf = await ls.workspaceConfigurationWait()
  if not conf.autoCheckProject.get(true):
    return

  if conf.useNimCheck.get(USE_NIM_CHECK_BY_DEFAULT):
    let nimPath = await ls.getNimPath(conf, uriToPath(uri))
    if nimPath.isNone:
      return

    proc getFilePath(c: CheckResult): string =
      c.file

    let token = ls.createProgressToken()
    ls.workDoneProgressCreate(token)
    ls.progress(token, "begin", fmt "Checking project {uri}")
    defer:
      ls.progress(token, "end")
    if uri == "":
      warn "Checking project with empty uri", uri = uri
      return
    let diagnostics = await nimCheck(uriToPath(uri), nimPath.get)
    let filesWithDiags = diagnostics.map(r => r.file).toHashSet

    debug "Found diagnostics", file = filesWithDiags
    for (path, diags) in groupBy(diagnostics, getFilePath):
      ls.sendDiagnostics(diags, path)

    # clean files with no diags
    for path in ls.filesWithDiags:
      if not filesWithDiags.contains path:
        debug "Sending zero diags", path = path
        let params =
          PublishDiagnosticsParams %* {"uri": pathToUri(path), "diagnostics": @[]}
        ls.notify("textDocument/publishDiagnostics", params)
    ls.filesWithDiags = filesWithDiags
    return

  debug "Running diagnostics", uri = uri
  let ns = await ls.tryGetNimsuggest(uri)
  if ns.isNone:
    return
  await ls.checkNimsuggestProject(uri, ns.get)

proc onErrorCallback(
    args: (LanguageServer, string), project: Project
): Future[void] {.async: (raises: []).} =
  let
    ls = args[0]
    uri = args[1]
  debug "Nimsuggest needed to be restarted due to an error "
  ls.failTable[project.file] = ls.failTable.getOrDefault(project.file, 0) + 1
  debug "Fail count", count = ls.failTable[project.file]
  warn "Server stopped.", projectFile = project.file
  try:
    let configuration = await ls.workspaceConfigurationWait()
    if configuration.autoRestart.get(true) and project.ns != nil and
        project.ns.successfullCall:
      await ls.createOrRestartNimsuggest(project.file, uri)
    else:
      await ls.showMessage(
        fmt "Server failed with {project.errorMessage}.", MessageType.Error
      )
  except CancelledError:
    let ex = getCurrentException()
    error "An error has ocurred while handling nimsuggest err", msg = ex.msg
    writeStackTrace(ex)
  finally:
    if project.file != "":
      ls.projectErrors.add ProjectError(
        projectFile: project.file,
        errorMessage: project.errorMessage,
        lastKnownCmd: project.lastCmd,
      )
      ls.sendStatusChanged()

proc createOrRestartNimsuggestImpl(
    ls: LanguageServer, projectFile: string, uri: string
): Future[void] {.async: (raises: [CancelledError]).} =
  let projectNext =
    try:
      debug "Starting createOrRestartNimsuggest", projectFile = projectFile, uri = uri
      let
        configuration = await ls.workspaceConfigurationWait()
        workingDir = await ls.getWorkingDir(projectFile)
        (nimsuggestPath, version) =
          await ls.getNimsuggestPathAndVersion(configuration, projectFile)
        timeout = configuration.timeout.get(REQUEST_TIMEOUT)
        restartCallback = proc(
            ns: Nimsuggest
        ): Future[void] {.async: (raises: [CancelledError]).} =
          warn "Restarting the server due to requests being to slow",
            projectFile = projectFile
          await ls.showMessage(
            fmt "Restarting nimsuggest for file {projectFile} due to timeout.",
            MessageType.Warning,
          )
          await ls.createOrRestartNimsuggest(projectFile, uri)
          ls.sendStatusChanged()
        errorCallback = partial(onErrorCallback, (ls, uri))

      debug "Creating new nimsuggest project", projectFile = projectFile

      let projectFut = createNimsuggest(
        projectFile,
        nimsuggestPath,
        version,
        timeout,
        restartCallback,
        errorCallback,
        workingDir,
        configuration.logNimsuggest.get(false),
        configuration.exceptionHintsEnabled,
        configuration.nimsuggestMaxMemory,
      )
      if not await chronos.withTimeout(
        projectFut,
        chronos.milliseconds(
          configuration.nimsuggestTimeout.get(NIMSUGGEST_STARTUP_TIMEOUT)
        ),
      ):
        error "Nimsuggest startup timed out", projectFile = projectFile
        nil
      else:
        await projectFut
    except CancelledError as exc:
      debug "Create/restart nimsuggest cancelled", projectFile = projectFile
      raise exc
    except ValueError, OSError, IOError, AsyncProcessError, AsyncStreamError:
      error "Failed to create/restart nimsuggest",
        projectFile = projectFile, error = getCurrentExceptionMsg()
      nil

  if projectNext != nil:
    debug "Nimsuggest initialized successfully", projectFile = projectFile
    let project = ls.projectFiles.getOrDefault(projectFile)
    if project != nil:
      project.stop()
    ls.projectFiles[projectFile] = projectNext
    ls.failTable.del(projectFile)
    traceAsyncErrors ls.checkProject(uri)
    ls.sendStatusChanged()
    await ls.showMessage(
      fmt "Nimsuggest initialized for {projectFile}", MessageType.Info
    )

proc createOrRestartNimsuggestUnprotected(
    ls: LanguageServer, projectFile: string, uri: string
): Future[void] {.async: (raises: [CancelledError]).} =
  if ls.isShutdownNimsuggest:
    debug "Not starting nimsuggest, the server is shutting down",
      projectFile = projectFile
    return
  let inFlight = ls.nimsuggestCreations.getOrDefault(projectFile)
  if not inFlight.isNil and not inFlight.finished:
    await inFlight
  else:
    let creation = ls.createOrRestartNimsuggestImpl(projectFile, uri)
    ls.nimsuggestCreations[projectFile] = creation
    try:
      await creation
    finally:
      if ls.nimsuggestCreations.getOrDefault(projectFile) == creation:
        ls.nimsuggestCreations.del(projectFile)

proc createOrRestartNimsuggest*(
    ls: LanguageServer, projectFile: string, uri = ""
): Future[void] {.async: (raw: true, raises: [CancelledError]).} =
  ls.createOrRestartNimsuggestUnprotected(projectFile, uri).join()

proc stopNimsuggests(ls: LanguageServer) {.async: (raises: []).} =
  debug "Stopping all nimsuggest instances"
  let
    creations = toSeq(ls.nimsuggestCreations.values)
    projects = toSeq(ls.projectFiles.values)
  ls.nimsuggestCreations.clear()
  ls.projectFiles.clear()
  var stops: seq[Future[void].Raising([])]
  for creation in creations:
    stops.add creation.cancelAndWait()
  for project in projects:
    project.errorCallback = none(ProjectCallback)
    stops.add project.stopWait()
  await noCancel allFutures(stops)

proc maybeRegisterCapabilityDidChangeConfiguration*(
    ls: LanguageServer
) {.async: (raises: [CancelledError]).} =
  if ls.requiresDynamicRegistrationForDidChangeConfiguration:
    let registrationParams = RegistrationParams(
      registrations: some(
        @[
          Registration(
            id: "a4606617-82c1-4e22-83db-0095fecb1093",
            `method`: "workspace/didChangeConfiguration",
          )
        ]
      )
    )
    try:
      let res = await ls.call("client/registerCapability", registrationParams)
      debug "Got response for the didChangeConfiguration registration:", res = $res
    except JsonRpcError as err:
      warn "The didChangeConfiguration registration failed", err = err.msg

proc maybeRegisterCapabilityDidChangeWatchedFiles*(
    ls: LanguageServer
) {.async: (raises: [CancelledError]).} =
  if ls.supportsDynamicRegistrationForDidChangeWatchedFiles:
    let watchers = @[
      FileSystemWatcher(
        globPattern: "**/*.nim",
        kind: some(WatchKind.Create.int or WatchKind.Change.int or WatchKind.Delete.int),
      )
    ]
    let reg = Registration(
      id: "workspace-did-change-watched-files",
      `method`: "workspace/didChangeWatchedFiles",
      registerOptions:
        some(%DidChangeWatchedFilesRegistrationOptions(watchers: some(watchers))),
    )
    let regParams = RegistrationParams(registrations: some(@[reg]))
    try:
      let res = await ls.call("client/registerCapability", regParams)
      debug "Got response for the didChangeWatchedFiles registration:", res = $res
      ls.watchingFiles = true
    except JsonRpcError as err:
      warn "The didChangeWatchedFiles registration failed", err = err.msg

proc markNimsuggestsStale*(ls: LanguageServer) =
  for project in ls.projectFiles.values:
    if project.ns != nil:
      project.ns.stale = true

proc handleConfigurationChanges*(
    ls: LanguageServer, oldConfiguration, newConfiguration: NlsConfig
): Future[void] {.async: (raises: [CancelledError]).} =
  if $(%oldConfiguration) == $(%newConfiguration):
    return
  let stopping = ls.stopNimsuggests()
  defer:
    await stopping
  for uri, file in ls.openFiles:
    file.projectFile = ls.getProjectFile(uri.uriToPath)
    file.nimsuggestProject = ""
  ls.sendStatusChanged()
  if ls.lspClientCapabilities.workspace.isSome and
      ls.lspClientCapabilities.workspace.get.inlayHint.isSome and
      ls.lspClientCapabilities.workspace.get.inlayHint.get.refreshSupport.get(false):
    debug "Sending inlayHint refresh"
    #An empty object means no params at all
    ls.inlayHintsRefreshRequest = ls.call("workspace/inlayHint/refresh", JsonString"{}")

proc maybeRequestConfigurationFromClient*(
    ls: LanguageServer
): Future[void] {.async: (raises: []).} =
  if ls.supportsConfigurationRequest:
    debug "Requesting configuration from the client"
    try:
      let configurationParams = ConfigurationParams %* {"items": [{"section": "nim"}]}
      let configuration = await ls.call("workspace/configuration", configurationParams)
      debug "Received the following configuration", configuration = $configuration
      #the first configuration is not a change, so there is nothing to handle
      let
        hadConfiguration = ls.workspaceConfigurationReady.finished
        oldConfiguration = ls.workspaceConfiguration
      ls.setWorkspaceConfiguration(configuration)
      if hadConfiguration:
        await ls.handleConfigurationChanges(oldConfiguration, ls.workspaceConfiguration)
    except CancelledError:
      error "Failed to handle the client configuration",
        error = getCurrentExceptionMsg()
    except JsonRpcError as exc:
      error "Failed to request the client configuration", error = exc.msg
      if not ls.workspaceConfigurationReady.finished():
        ls.setWorkspaceConfiguration(newJArray())
  else:
    debug "Client does not support workspace/configuration"
    if not ls.workspaceConfigurationReady.finished():
      ls.setWorkspaceConfiguration(newJArray())

proc getCharacter*(
    ls: LanguageServer, uri: string, line: int, character: int
): Option[int] =
  let info = ls.openFiles.getOrDefault(uri)
  if info != nil and line in 0 ..< info.fingerTable.len:
    some info.fingerTable[line].utf16to8(character)
  else:
    none(int)

proc shutdownNimsuggestImpl(ls: LanguageServer) {.async: (raises: []).} =
  debug "stopping child nimsuggest processes"
  var shutdowns: seq[Future[void].Raising([])]
  for load in ls.nimblePackageLoads.values:
    shutdowns.add load.cancelAndWait()
  shutdowns.add ls.stopNimsuggests()
  await noCancel allFutures(shutdowns)

proc shutdownNimsuggest*(ls: LanguageServer) {.async: (raises: []).} =
  if ls.nimsuggestShutdown == nil:
    ls.nimsuggestShutdown = ls.shutdownNimsuggestImpl()
  await noCancel ls.nimsuggestShutdown

proc getProjectFile*(
    ls: LanguageServer, uri: string
): Future[string] {.async: (raises: [CancelledError, OSError, RegexError]).} =
  let
    rootPath = ls.getRootPath()
    pathRelativeToRoot = uri.tryRelativeTo(rootPath)
    conf = await ls.workspaceConfigurationWait()
    mappings = conf.projectMapping.get(@[])

  for mapping in mappings:
    var m: RegexMatch2
    if pathRelativeToRoot.isSome and
        find(pathRelativeToRoot.get(), re2(mapping.fileRegex), m):
      await ls.showMessage(
        fmt"RegEx matched `{mapping.fileRegex}` for file `{uri}`", MessageType.Info
      )
      result = rootPath / mapping.projectFile
      if fileExists(result):
        trace "getProjectFile?",
          project = result, uri = uri, matchedRegex = mapping.fileRegex
        return result
    else:
      trace "getProjectFile does not match", uri = uri, matchedRegex = mapping.fileRegex

  let package = await ls.nimblePackage(uri)
  if package.projectFile.len > 0:
    debug "Found nimble project", projectFile = package.projectFile
    result = package.projectFile
  else:
    result = await ls.getProjectFileAutoGuess(uri)

  if result == "":
    result = uri

  debug "getProjectFile ", project = result, uri = uri

proc checkFile*(
    ls: LanguageServer, file: NlsFileInfo
): Future[void] {.
    async: (
      raises: [
        CancelledError, AsyncProcessError, AsyncStreamError, OSError, IOError,
        RegexError, NimsuggestError,
      ]
    )
.} =
  let uri = file.textDocument.uri
  let edits = file.edits
  let conf = await ls.workspaceConfigurationWait()
  let token = ls.createProgressToken()
  ls.workDoneProgressCreate(token)
  ls.progress(token, "begin", fmt "Checking {uri.uriToPath}")
  defer:
    ls.progress(token, "end")

  let path = uriToPath(uri)

  if conf.useNimCheck.get(USE_NIM_CHECK_BY_DEFAULT):
    let nimPath = await ls.getNimPath(conf, path)
    if nimPath.isNone:
      return
    let checkResults = await nimCheck(uriToPath(uri), nimPath.get)
    if file.edits == edits:
      ls.sendDiagnostics(checkResults, path)
    return

  let closed = uri notin ls.openFiles
  let ns =
    if closed:
      let project = ls.projectFiles.getOrDefault(file.nimsuggestProject)
      if project != nil:
        some project.ns
      else:
        none(Nimsuggest)
    else:
      await ls.tryGetNimsuggest(uri)
  let dirtyFile =
    if closed:
      path
    else:
      ls.uriToStash(uri)
  if ns.isSome:
    let diagnostics = await ns.get().chkFile(path, dirtyFile)
    if file.edits == edits:
      ls.sendDiagnostics(diagnostics, path)

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

proc removeIdleNimsuggests*(
    ls: LanguageServer
) {.async: (raises: [CancelledError, OSError]).} =
  if ls.projectFiles.len == 0:
    return
  const DefaultNimsuggestIdleTimeout = 120000
  let conf = await ls.workspaceConfigurationWait()
  let timeout = conf.nimsuggestIdleTimeout.get(DefaultNimsuggestIdleTimeout)
  let mappedProjects = ls.mappedProjectFiles(conf)
  var toStop = newSeq[Project]()
  for project in ls.projectFiles.values:
    if project.file in ls.entryPoints or project.file in mappedProjects:
      #we only remove non entry point nimsuggests
      continue
    if project.lastCmdDate.isSome:
      let passedTime = now() - project.lastCmdDate.get()
      if passedTime.inMilliseconds > timeout:
        toStop.add(project)

  for project in toStop:
    debug "Removing idle nimsuggest", project = project.file
    project.errorCallback = none(ProjectCallback)
    project.stop()
    ls.projectFiles.del(project.file)

    await ls.showMessage(
      fmt"Nimsuggest for {project.file} was stopped because it was idle for too long",
      MessageType.Info,
    )

proc tick*(ls: LanguageServer): Future[void] {.async: (raises: []).} =
  # debug "Ticking at ", now = now(), prs = ls.pendingRequests.len
  try:
    ls.removeCompletedPendingRequests()
    await ls.removeIdleNimsuggests()
    ls.sendStatusChanged
  except CancelledError, OSError:
    let ex = getCurrentException()
    error "Error in tick", msg = ex.msg
    writeStackTrace(ex)
