import
  macros,
  strformat,
  chronos,
  chronos/threadsync,
  os,
  sugar,
  hashes,
  osproc,
  suggestapi,
  protocol/enums,
  protocol/types,
  with,
  tables,
  strutils,
  sets,
  ./utils,
  chronicles,
  std/[json, streams, sequtils, setutils, times],
  uri,
  json_serialization,
  json_rpc/[servers/socketserver],
  regex,
  nimcheck

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
  CRLF* = "\r\n"
  CONTENT_LENGTH* = "Content-Length: "
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

  NlsFileInfo* = ref object of RootObj
    projectFile*: Future[string]
    changed*: bool
    fingerTable*: seq[seq[tuple[u16pos, offset: int]]]
    cancelFileCheck*: Future[void]
    checkInProgress*: bool
    needsChecking*: bool

  CommandLineParams* = object
    clientProcessId*: Option[int]
    transport*: Option[TransportMode]
    port*: Port #only for sockets

  TransportMode* = enum
    stdio = "stdio"
    socket = "socket"

  ReadStdinContext* = object
    onStdReadSignal*: ThreadSignalPtr #used by the thread to notify it read from the std
    onMainReadSignal*: ThreadSignalPtr
      #used by the main thread to notify it read the value from the signal
    value*: cstring

  PendingRequestState* = enum
    prsOnGoing = "OnGoing"
    prsCancelled = "Cancelled"
    prsComplete = "Complete"

  PendingRequest* = object
    id*: uint
    name*: string
    request*: Future[JsonString]
    projectFile*: Option[string]
    startTime*: DateTime
    endTime*: DateTime
    state*: PendingRequestState

  LanguageServer* = ref object
    clientCapabilities*: ClientCapabilities
    serverCapabilities*: ServerCapabilities
    extensionCapabilities*: set[LspExtensionCapability]
    initializeParams*: InitializeParams
    notify*: NotifyAction
    call*: CallAction
    onExit*: OnExitCallback
    projectFiles*: Table[string, Project]
    openFiles*: Table[string, NlsFileInfo]
    workspaceConfiguration*: Future[JsonNode]
    prevWorkspaceConfiguration*: Future[JsonNode]
    inlayHintsRefreshRequest*: Future[JsonNode]
    didChangeConfigurationRegistrationRequest*: Future[JsonNode]
    filesWithDiags*: HashSet[string]
    lastNimsuggest*: Future[Nimsuggest]
    childNimsuggestProcessesStopped*: bool
    isShutdown*: bool
    storageDir*: string
    cmdLineClientProcessId*: Option[int]
    nimDumpCache*: Table[string, NimbleDumpInfo] #path to NimbleDumpInfo
    entryPoints*: seq[string]
    responseMap*: TableRef[string, Future[JsonNode]]
      #id to future. Represents the pending requests as result of calling ls.call
    srv*: RpcSocketServer
      #Both modes uses it to store the routes. Only actually started in socket mode
    pendingRequests*: Table[uint, PendingRequest]
      #id to future. Each request is added here so we can cancel them later in the cancelRequest. Only requests, not notifications
    case transportMode*: TransportMode
    of socket:
      socketTransport*: StreamTransport
    of stdio:
      outStream*: FileStream
      stdinContext*: ptr ReadStdinContext
    projectErrors*: seq[ProjectError]
    lastStatusSent: JsonNode
      #List of errors (crashes) nimsuggest has had since the lsp session started

  Certainty* = enum
    None
    Folder
    Cfg
    Nimble

  NimbleDumpInfo* = object
    srcDir*: string
    name*: string
    nimDir*: Option[string]
    nimblePath*: Option[string]
    entryPoints*: seq[string] #when it's empty, means the nimble version doesnt dump it.

  OnExitCallback* = proc(): Future[void] {.gcsafe, raises: [].}
    #To be called when the server is shutting down
  NotifyAction* = proc(name: string, params: JsonNode) {.gcsafe, raises: [].}
    #Send a notification to the client
  CallAction* =
    proc(name: string, params: JsonNode): Future[JsonNode] {.gcsafe, raises: [].}
    #Send a request to the client

macro `%*`*(t: untyped, inputStream: untyped): untyped =
  result =
    newCall(bindSym("to", brOpen), newCall(bindSym("%*", brOpen), inputStream), t)

proc initLs*(params: CommandLineParams, storageDir: string): LanguageServer =
  LanguageServer(
    workspaceConfiguration: Future[JsonNode](),
    filesWithDiags: initHashSet[string](),
    transportMode: params.transport.get(),
    openFiles: initTable[string, NlsFileInfo](),
    responseMap: newTable[string, Future[JsonNode]](),
    storageDir: storageDir,
    cmdLineClientProcessId: params.clientProcessId,
    extensionCapabilities: LspExtensionCapability.items.toSet,
  )

proc getNimbleEntryPoints*(
    dumpInfo: NimbleDumpInfo, nimbleProjectPath: string
): seq[string] =
  if dumpInfo.entryPoints.len > 0:
    result = dumpInfo.entryPoints.mapIt(nimbleProjectPath / it)
  else:
    #Nimble doesnt include the entry points, returning the nimble project file as the entry point
    let sourceDir = nimbleProjectPath / dumpInfo.srcDir
    result = @[sourceDir / (dumpInfo.name & ".nim")]
  result = result.filterIt(it.fileExists)

func typeHintsEnabled*(cnf: NlsConfig): bool =
  result = true
  if cnf.inlayHints.isSome and cnf.inlayHints.get.typeHints.isSome and
      cnf.inlayHints.get.typeHints.get.enable.isSome:
    result = cnf.inlayHints.get.typeHints.get.enable.get

func exceptionHintsEnabled*(cnf: NlsConfig): bool =
  result = true
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

proc supportSignatureHelp*(cc: ClientCapabilities): bool =
  if cc.isNil:
    return false
  let caps = cc.textDocument
  caps.isSome and caps.get.signatureHelp.isSome

proc getNimbleDumpInfo*(ls: LanguageServer, nimbleFile: string): NimbleDumpInfo =
  if nimbleFile in ls.nimDumpCache:
    return ls.nimDumpCache.getOrDefault(nimbleFile)
  try:
    let info = execProcess("nimble dump " & nimbleFile)
    for line in info.splitLines:
      if line.startsWith("srcDir"):
        result.srcDir = line[(1 + line.find '"') ..^ 2]
      if line.startsWith("name"):
        result.name = line[(1 + line.find '"') ..^ 2]
      if line.startsWith("nimDir"):
        result.nimDir = some line[(1 + line.find '"') ..^ 2]
      if line.startsWith("nimblePath"):
        result.nimblePath = some line[(1 + line.find '"') ..^ 2]
      if line.startsWith("entryPoints"):
        result.entryPoints =
          line[(1 + line.find '"') ..^ 2].split(',').mapIt(it.strip(chars = {' ', '"'}))

    var nimbleFile = nimbleFile
    if nimbleFile == "" and result.nimblePath.isSome:
      nimbleFile = result.nimblePath.get
    if nimbleFile != "":
      ls.nimDumpCache[nimbleFile] = result
  except OSError, IOError:
    debug "Failed to get nimble dump info", nimbleFile = nimbleFile

proc parseWorkspaceConfiguration*(conf: JsonNode): NlsConfig =
  try:
    if conf.kind == JObject and conf["settings"].kind == JObject:
      return conf["settings"]["nim"].to(NlsConfig)
  except CatchableError:
    discard
  try:
    let nlsConfig: seq[NlsConfig] = (%conf).to(seq[NlsConfig])
    result =
      if nlsConfig.len > 0 and nlsConfig[0] != nil:
        nlsConfig[0]
      else:
        NlsConfig()
  except CatchableError:
    debug "Failed to parse the configuration.", error = getCurrentExceptionMsg()
    result = NlsConfig()

proc getWorkspaceConfiguration*(
    ls: LanguageServer, retries = 0
): Future[NlsConfig] {.async: (raises: []).} =
  try:
    #this is the root of a lot a problems as there are multiple race conditions here.
    #since most request doenst really rely on the configuration, we can just go ahead and 
    #return a default one until we have the right one. 
    #TODO review and handle project specific confs when received instead of reliying in this func
    if ls.workspaceConfiguration.finished:
      return parseWorkspaceConfiguration(ls.workspaceConfiguration.read)
    else:
      if retries < 3: 
        await sleepAsync(100)
        return await ls.getWorkspaceConfiguration(retries + 1)
    debug "Failed to get workspace configuration, returning default"
    return NlsConfig()
  except CatchableError as ex:
    error "Failed to get workspace configuration", error = ex.msg
    writeStackTrace(ex)

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
  for project in ls.projectFiles.values:
    let futNs = project.ns
    if futNs.finished:
      try:
        var ns = futNs.read
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
  if id in ls.pendingRequests:
    var projectFile = uri.uriToPath()
    if projectFile notin ls.projectFiles:
      if uri in ls.openFiles:
        projectFile = await ls.openFiles[uri].projectFile

    ls.pendingRequests[id].projectFile = some projectFile
    ls.sendStatusChanged

proc requiresDynamicRegistrationForDidChangeConfiguration(ls: LanguageServer): bool =
  ls.clientCapabilities.workspace.isSome and
    ls.clientCapabilities.workspace.get.didChangeConfiguration.isSome and
    ls.clientCapabilities.workspace.get.didChangeConfiguration.get.dynamicRegistration.get(
      false
    )

proc supportsConfigurationRequest(ls: LanguageServer): bool =
  ls.clientCapabilities.workspace.isSome and
    ls.clientCapabilities.workspace.get.configuration.get(false)

proc usePullConfigurationModel*(ls: LanguageServer): bool =
  ls.requiresDynamicRegistrationForDidChangeConfiguration and
    ls.supportsConfigurationRequest

proc inlayExceptionHintsConfigurationEquals*(a, b: NlsInlayHintsConfig): bool =
  if a.exceptionHints.isSome and b.exceptionHints.isSome:
    let
      ae = a.exceptionHints.get
      be = b.exceptionHints.get
    result =
      (ae.enable == be.enable) and (ae.hintStringLeft == be.hintStringLeft) and
      (ae.hintStringRight == be.hintStringRight)
  else:
    result = a.exceptionHints.isSome == b.exceptionHints.isSome

proc inlayExceptionHintsConfigurationEquals*(a, b: NlsConfig): bool =
  if a.inlayHints.isSome and b.inlayHints.isSome:
    result = inlayExceptionHintsConfigurationEquals(a.inlayHints.get, b.inlayHints.get)
  else:
    result = a.inlayHints.isSome == b.inlayHints.isSome

proc inlayHintsConfigurationEquals*(a, b: NlsConfig): bool =
  proc inlayTypeHintsConfigurationEquals(a, b: NlsInlayHintsConfig): bool =
    if a.typeHints.isSome and b.typeHints.isSome:
      result = a.typeHints.get.enable == b.typeHints.get.enable
    else:
      result = a.typeHints.isSome == b.typeHints.isSome

  proc inlayHintsConfigurationEquals(a, b: NlsInlayHintsConfig): bool =
    result =
      inlayTypeHintsConfigurationEquals(a, b) and
      inlayExceptionHintsConfigurationEquals(a, b)

  if a.inlayHints.isSome and b.inlayHints.isSome:
    result = inlayHintsConfigurationEquals(a.inlayHints.get, b.inlayHints.get)
  else:
    result = a.inlayHints.isSome == b.inlayHints.isSome

proc getNimVersion(nimDir: string): string =
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

proc getNimSuggestPathAndVersion(
    ls: LanguageServer, conf: NlsConfig, workingDir: string
): (string, string) =
  #Attempting to see if the project is using a custom Nim version, if it's the case this will be slower than usual
  let nimbleDumpInfo = ls.getNimbleDumpInfo("")
  let nimDir = nimbleDumpInfo.nimDir.get ""

  var nimsuggestPath = expandTilde(conf.nimsuggestPath.get(""))
  var nimVersion = ""
  if nimsuggestPath == "":
    if nimDir != "" and nimDir.dirExists:
      nimVersion = getNimVersion(nimDir) & " from " & nimDir
      nimsuggestPath = nimDir / "nimsuggest"
    else:
      nimVersion = getNimVersion("")
      nimsuggestPath = findExe "nimsuggest"
  else:
    nimVersion = getNimVersion(nimsuggestPath.parentDir)
  ls.showMessage(fmt "Using {nimVersion}", MessageType.Info)
  (nimsuggestPath, nimVersion)

proc getProjectFileAutoGuess*(ls: LanguageServer, fileUri: string): string =
  let file = fileUri.decodeUrl
  debug "Auto-guessing project file for", file = file
  result = file
  let (dir, _, _) = result.splitFile()
  var
    path = dir
    certainty = Certainty.None
    up = 0
      #Limit the times it goes up through the directories. Ideally nimble dump should do this job
  while path.len > 0 and path != "/" and up < 2:
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
        let dumpInfo = ls.getNimbleDumpInfo(nimble)
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

proc getRootPath*(ip: InitializeParams): string =
  if ip.rootUri.isNone or ip.rootUri.get == "":
    if ip.rootPath.isSome and ip.rootPath.get != "":
      return ip.rootPath.get
    else:
      return getCurrentDir().pathToUri.uriToPath
  return ip.rootUri.get.uriToPath

proc getWorkingDir(ls: LanguageServer, path: string): Future[string] {.async.} =
  let
    rootPath = ls.initializeParams.getRootPath
    pathRelativeToRoot = path.tryRelativeTo(rootPath)
    mapping = ls.getWorkspaceConfiguration.await().workingDirectoryMapping.get(@[])

  result = getCurrentDir()

  for m in mapping:
    if pathRelativeToRoot.isSome and m.projectFile == pathRelativeToRoot.get():
      result = rootPath.string / m.directory
      break

proc progressSupported(ls: LanguageServer): bool =
  result = ls.initializeParams.capabilities.window
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
    let fileData = ls.openFiles[uri]
    if fileData != nil:
      let cancelFileCheck = fileData.cancelFileCheck
      if cancelFileCheck != nil and not cancelFileCheck.finished:
        cancelFileCheck.complete()
      fileData.needsChecking = false

proc uriStorageLocation*(ls: LanguageServer, uri: string): string =
  ls.storageDir / (hash(uri).toHex & ".nim")

proc uriToStash*(ls: LanguageServer, uri: string): string =
  if ls.openFiles.hasKey(uri) and ls.openFiles[uri].changed:
    uriStorageLocation(ls, uri)
  else:
    ""

proc toUtf16Pos*(
    ls: LanguageServer, uri: string, line: int, utf8Pos: int
): Option[int] =
  if uri in ls.openFiles and line >= 0 and line < ls.openFiles[uri].fingerTable.len:
    let utf16Pos = ls.openFiles[uri].fingerTable[line].utf8to16(utf8Pos)
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
  
  for i in 0..<result.stacktrace.len:
    let stPos = toUtf16Pos(ls, uri, result.stacktrace[i].line - 1, result.stacktrace[i].column)
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
        if textStart >= 0 and textEnd >= 0:
          column + utf16Len(doc[textStart + 1 ..< textEnd])
        else:
          column + 1

    let node =
      %*{
        "uri": pathToUri(filepath),
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
    return node.to(Diagnostic)

proc toDiagnostic(checkResult: CheckResult): Diagnostic =
  let
    textStart = checkResult.msg.find('\'')
    textEnd = checkResult.msg.rfind('\'')
    endColumn =
      if textStart >= 0 and textEnd >= 0:
        checkResult.column + utf16Len(checkResult.msg[textStart + 1 ..< textEnd])
      else:
        checkResult.column + 1

  let node =
    %*{
      "uri": pathToUri(checkResult.file),
      "range": range(checkResult.line - 1, checkResult.column, checkResult.line - 1, endColumn),
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
  return node.to(Diagnostic)

proc sendDiagnostics*(ls: LanguageServer, diagnostics: seq[Suggest] | seq[CheckResult], path: string) =
  debug "Sending diagnostics", count = diagnostics.len, path = path
  let params =
    PublishDiagnosticsParams %*
    {"uri": pathToUri(path), "diagnostics": diagnostics.map(x => x.toUtf16Pos(ls).toDiagnostic)}
  ls.notify("textDocument/publishDiagnostics", %params)

  if diagnostics.len != 0:
    ls.filesWithDiags.incl path
  else:
    ls.filesWithDiags.excl path

proc tryGetNimsuggest*(
  ls: LanguageServer, uri: string
): Future[Option[Nimsuggest]] {.async.}

proc checkProject*(ls: LanguageServer, uri: string): Future[void] {.async, gcsafe.} =
  if not ls.getWorkspaceConfiguration.await().autoCheckProject.get(true):
    return
  let useNimCheck = ls.getWorkspaceConfiguration.await().useNimCheck.get(true)
  
  let nimPath = "nim"

  if useNimCheck:
    proc getFilePath(c: CheckResult): string = c.file

    let token = fmt "Checking {uri}"
    ls.workDoneProgressCreate(token)
    ls.progress(token, "begin", fmt "Checking project {uri}")
    if uri == "":
      warn "Checking project with empty uri", uri = uri
      ls.progress(token, "end")
      return
    let diagnostics = await nimCheck(uriToPath(uri), nimPath)
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
  let ns = ls.tryGetNimsuggest(uri).await
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
  nimsuggest.checkProjectInProgress = false

  if nimsuggest.needsCheckProject:
    nimsuggest.needsCheckProject = false
    callSoon do() {.gcsafe.}:
      debug "Running delayed check project...", uri = uri
      traceAsyncErrors ls.checkProject(uri)

proc createOrRestartNimsuggest*(
  ls: LanguageServer, projectFile: string, uri = ""
) {.gcsafe, raises: [].}

proc onErrorCallback(args: (LanguageServer, string), project: Project) =
  let
    ls = args[0]
    uri = args[1]
  debug "NimSuggest needed to be restarted due to an error "
  let configuration = ls.getWorkspaceConfiguration().waitFor()
  warn "Server stopped.", projectFile = project.file
  try:
    if configuration.autoRestart.get(true) and project.ns.completed and
        project.ns.read.successfullCall:
      ls.createOrRestartNimsuggest(project.file, uri)
    else:
      ls.showMessage(
        fmt "Server failed with {project.errorMessage}.", MessageType.Error
      )
  except CatchableError as ex:
    error "An error has ocurred while handling nimsuggest err", msg = ex.msg
    writeStacktrace(ex)
  finally:
    if project.file != "":
      ls.projectErrors.add ProjectError(
        projectFile: project.file,
        errorMessage: project.errorMessage,
        lastKnownCmd: project.lastCmd,
      )
      ls.sendStatusChanged()

proc createOrRestartNimsuggest*(
    ls: LanguageServer, projectFile: string, uri = ""
) {.gcsafe, raises: [].} =
  try:
    let
      configuration = ls.getWorkspaceConfiguration().waitFor()
      workingDir = ls.getWorkingDir(projectFile).waitFor()
      (nimsuggestPath, version) =
        ls.getNimSuggestPathAndVersion(configuration, workingDir)
      timeout = configuration.timeout.get(REQUEST_TIMEOUT)
      restartCallback = proc(ns: Nimsuggest) {.gcsafe, raises: [].} =
        warn "Restarting the server due to requests being to slow",
          projectFile = projectFile
        ls.showMessage(
          fmt "Restarting nimsuggest for file {projectFile} due to timeout.",
          MessageType.Warning,
        )
        ls.createOrRestartNimsuggest(projectFile, uri)
        ls.sendStatusChanged()
      errorCallback = partial(onErrorCallback, (ls, uri))
      #TODO instead of waiting here, this whole function should be async. 
      projectNext = waitFor createNimsuggest(
        projectFile,
        nimsuggestPath,
        version,
        timeout,
        restartCallback,
        errorCallback,
        workingDir,
        configuration.logNimsuggest.get(false),
        configuration.exceptionHintsEnabled,
      )
      token = fmt "Creating nimsuggest for {projectFile}"

    ls.workDoneProgressCreate(token)

    if ls.projectFiles.hasKey(projectFile):
      var project = ls.projectFiles[projectFile]
      project.stop()
      ls.projectFiles[projectFile] = projectNext
      ls.progress(token, "begin", fmt "Restarting nimsuggest for {projectFile}")
    else:
      ls.progress(token, "begin", fmt "Creating nimsuggest for {projectFile}")
      ls.projectFiles[projectFile] = projectNext

    projectNext.ns.addCallback do(fut: Future[Nimsuggest]):
      if fut.read.project.failed:
        let msg = fut.read.project.errorMessage
        ls.showMessage(
          fmt "Nimsuggest initialization for {projectFile} failed with: {msg}",
          MessageType.Error,
        )
      else:
        ls.showMessage(fmt "Nimsuggest initialized for {projectFile}", MessageType.Info)
        traceAsyncErrors ls.checkProject(uri)
        fut.read().openFiles.incl uri
      ls.progress(token, "end")
      ls.sendStatusChanged()
  except CatchableError:
    discard

proc getNimsuggestInner(ls: LanguageServer, uri: string): Future[Nimsuggest] {.async.} =
  assert uri in ls.openFiles, "File not open"

  let projectFile = await ls.openFiles[uri].projectFile
  if not ls.projectFiles.hasKey(projectFile):
    ls.createOrRestartNimsuggest(projectFile, uri)

  ls.lastNimsuggest = ls.projectFiles[projectFile].ns
  return await ls.projectFiles[projectFile].ns

proc tryGetNimsuggest*(
    ls: LanguageServer, uri: string
): Future[Option[Nimsuggest]] {.async.} =
  if uri notin ls.openFiles:
    none(NimSuggest)
  else:
    some await getNimsuggestInner(ls, uri)

proc restartAllNimsuggestInstances(ls: LanguageServer) =
  debug "Restarting all nimsuggest instances"
  for projectFile in ls.projectFiles.keys:
    ls.createOrRestartNimsuggest(projectFile, projectFile.pathToUri)

proc maybeRegisterCapabilityDidChangeConfiguration*(ls: LanguageServer) =
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
    ls.didChangeConfigurationRegistrationRequest =
      ls.call("client/registerCapability", %registrationParams)
    ls.didChangeConfigurationRegistrationRequest.addCallback do(res: Future[JsonNode]):
      debug "Got response for the didChangeConfiguration registration:",
        res = res.read()

proc handleConfigurationChanges*(
    ls: LanguageServer, oldConfiguration, newConfiguration: NlsConfig
) =
  if ls.clientCapabilities.workspace.isSome and
      ls.clientCapabilities.workspace.get.inlayHint.isSome and
      ls.clientCapabilities.workspace.get.inlayHint.get.refreshSupport.get(false) and
      not inlayHintsConfigurationEquals(oldConfiguration, newConfiguration):
    # toggling the exception hints triggers a full nimsuggest restart, since they are controlled by a nimsuggest command line option
    #   --exceptionInlayHints:on|off
    if not inlayExceptionHintsConfigurationEquals(oldConfiguration, newConfiguration):
      ls.restartAllNimsuggestInstances
    debug "Sending inlayHint refresh"
    ls.inlayHintsRefreshRequest = ls.call("workspace/inlayHint/refresh", newJNull())

proc maybeRequestConfigurationFromClient*(ls: LanguageServer) =
  if ls.supportsConfigurationRequest:
    debug "Requesting configuration from the client"
    let configurationParams = ConfigurationParams %* {"items": [{"section": "nim"}]}

    ls.prevWorkspaceConfiguration = ls.workspaceConfiguration

    ls.workspaceConfiguration = ls.call("workspace/configuration", %configurationParams)
    ls.workspaceConfiguration.addCallback do(futConfiguration: Future[JsonNode]):
      if futConfiguration.error.isNil:
        debug "Received the following configuration",
          configuration = futConfiguration.read()
        if not isNil(ls.prevWorkspaceConfiguration) and
            ls.prevWorkspaceConfiguration.finished:
          let
            oldConfiguration =
              parseWorkspaceConfiguration(ls.prevWorkspaceConfiguration.read)
            newConfiguration = parseWorkspaceConfiguration(futConfiguration.read)
          handleConfigurationChanges(ls, oldConfiguration, newConfiguration)
  else:
    debug "Client does not support workspace/configuration"
    ls.workspaceConfiguration.complete(newJArray())

proc getCharacter*(
    ls: LanguageServer, uri: string, line: int, character: int
): Option[int] =
  if uri in ls.openFiles and line < ls.openFiles[uri].fingerTable.len:
    return some ls.openFiles[uri].fingerTable[line].utf16to8(character)
  else:
    return none(int)

proc stopNimsuggestProcesses*(ls: LanguageServer) {.async.} =
  if not ls.childNimsuggestProcessesStopped:
    debug "stopping child nimsuggest processes"
    ls.childNimsuggestProcessesStopped = true
    for project in ls.projectFiles.values:
      project.stop()
  else:
    debug "child nimsuggest processes already stopped: CHECK!"

proc stopNimsuggestProcessesP*(ls: LanguageServer) =
  waitFor stopNimsuggestProcesses(ls)

proc getProjectFile*(fileUri: string, ls: LanguageServer): Future[string] {.async.} =
  let
    rootPath = ls.initializeParams.getRootPath
    pathRelativeToRoot = fileUri.tryRelativeTo(rootPath)
    mappings = ls.getWorkspaceConfiguration.await().projectMapping.get(@[])

  for mapping in mappings:
    var m: RegexMatch2
    if pathRelativeToRoot.isSome and
        find(pathRelativeToRoot.get(), re2(mapping.fileRegex), m):
      ls.showMessage(
        fmt"RegEx matched `{mapping.fileRegex}` for file `{fileUri}`", MessageType.Info
      )
      result = string(rootPath) / mapping.projectFile
      if fileExists(result):
        trace "getProjectFile?",
          project = result, uri = fileUri, matchedRegex = mapping.fileRegex
        return result
    else:
      trace "getProjectFile does not match",
        uri = fileUri, matchedRegex = mapping.fileRegex

  result = ls.getProjectFileAutoGuess(fileUri)
  if result in ls.projectFiles:
    let ns = await ls.projectFiles[result].ns
    let isKnown = await ns.isKnown(fileUri)
    if ns.canHandleUnknown and not isKnown:
      debug "File is not known by nimsuggest", uri = fileUri, projectFile = result
      result = fileUri

  if result == "":
    result = fileUri

  debug "getProjectFile ", project = result, fileUri = fileUri

proc warnIfUnknown*(
    ls: LanguageServer, ns: Nimsuggest, uri: string, projectFile: string
): Future[void] {.async, gcsafe.} =
  let path = uri.uriToPath
  let isFileKnown = await ns.isKnown(path)
  if not isFileKnown and not ns.canHandleUnknown:
    ls.showMessage(
      fmt """{path} is not compiled as part of project {projectFile}.
  In orde to get the IDE features working you must either configure nim.projectMapping or import the module.""",
      MessageType.Warning,
    )

proc checkFile*(ls: LanguageServer, uri: string): Future[void] {.async.} =
  let nimPath = "nim"  
  let useNimCheck = ls.getWorkspaceConfiguration.await().useNimCheck.get(true)

  let token = fmt "Checking file {uri}"
  ls.workDoneProgressCreate(token)
  ls.progress(token, "begin", fmt "Checking {uri.uriToPath}")

  let path = uriToPath(uri)

  if useNimCheck:
    let checkResults = await nimCheck(uriToPath(uri), nimPath)
    ls.progress(token, "end")
    ls.sendDiagnostics(checkResults, path)
    return

  let ns = await ls.tryGetNimsuggest(uri)
  if ns.isSome:
    let diagnostics = ns.get().chkFile(path, ls.uriToStash(uri)).await()
    ls.progress(token, "end")
    ls.sendDiagnostics(diagnostics, path)
  else:
    ls.progress(token, "end")

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

proc removeIdleNimsuggests*(ls: LanguageServer) {.async.} =
  const DefaultNimsuggestIdleTimeout = 120000
  let timeout = ls.getWorkspaceConfiguration().await().nimsuggestIdleTimeout.get(
      DefaultNimsuggestIdleTimeout
    )
  var toStop = newSeq[Project]()
  for project in ls.projectFiles.values:
    if project.file in ls.entryPoints: #we only remove non entry point nimsuggests
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
    ls.showMessage(
      fmt"Nimsuggest for {project.file} was stopped because it was idle for too long",
      MessageType.Info,
    )

proc tick*(ls: LanguageServer): Future[void] {.async.} =
  # debug "Ticking at ", now = now(), prs = ls.pendingRequests.len
  ls.removeCompletedPendingRequests()
  await ls.removeIdleNimsuggests()
  ls.sendStatusChanged
