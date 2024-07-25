import macros, strformat, faststreams/async_backend,
  faststreams/asynctools_adapters, faststreams/inputs,
  json_rpc/streamconnection, json_rpc/server, os, sugar, sequtils, hashes, osproc,
  suggestapi, protocol/enums, protocol/types, with, tables, strutils, sets,
  ./utils, chronicles, std/re, uri, "$nim/compiler/pathutils",
  json_serialization, serialization/formats, std/json


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

  NlsFileInfo* = ref object of RootObj
    projectFile*: Future[string]
    changed*: bool
    fingerTable*: seq[seq[tuple[u16pos, offset: int]]]
    cancelFileCheck*: Future[void]
    checkInProgress*: bool
    needsChecking*: bool

  CommandLineParams* = object
    clientProcessId*: Option[int]

  LanguageServer* = ref object
    clientCapabilities*: ClientCapabilities
    initializeParams*: InitializeParams
    connection*: StreamConnection #TODO remove this dep from here
    projectFiles*: Table[string, Future[Nimsuggest]]
    openFiles*: Table[string, NlsFileInfo]
    cancelFutures*: Table[int, Future[void]]
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

  Certainty* = enum
    None,
    Folder,
    Cfg,
    Nimble
  
  NimbleDumpInfo* = object
    srcDir*: string
    name*: string
    nimDir*: Option[string]
    nimblePath*: Option[string]
    entryPoints*: seq[string] #when it's empty, means the nimble version doesnt dump it.

macro `%*`*(t: untyped, inputStream: untyped): untyped =
  result = newCall(bindSym("to", brOpen),
                   newCall(bindSym("%*", brOpen), inputStream), t)

proc orCancelled*[T](fut: Future[T], ls: LanguageServer, id: int): Future[T] {.async.} =
  ls.cancelFutures[id] = newFuture[void]()
  await fut or ls.cancelFutures[id]
  ls.cancelFutures.del id
  if fut.finished:
    if fut.error.isNil:
      return fut.read
    else:
      raise fut.error
  else:
    debug "Future cancelled.", id = id
    let ex = newException(Cancelled, fmt "Cancelled {id}")
    fut.fail(ex)
    debug "Future cancelled, throwing...", id = id
    raise ex

proc getNimbleEntryPoints*(dumpInfo: NimbleDumpInfo, nimbleProjectPath: string): seq[string] =
  if dumpInfo.entryPoints.len > 0:
    result = dumpInfo.entryPoints.mapIt(nimbleProjectPath / it)
  else:
    #Nimble doesnt include the entry points, returning the nimble project file as the entry point
    let sourceDir = nimbleProjectPath / dumpInfo.srcDir
    result = @[sourceDir / (dumpInfo.name & ".nim")]
  result = result.filterIt(it.fileExists)

func typeHintsEnabled*(cnf: NlsConfig): bool =
  result = true
  if cnf.inlayHints.isSome and cnf.inlayHints.get.typeHints.isSome and cnf.inlayHints.get.typeHints.get.enable.isSome:
    result = cnf.inlayHints.get.typeHints.get.enable.get

func exceptionHintsEnabled*(cnf: NlsConfig): bool =
  result = true
  if cnf.inlayHints.isSome and cnf.inlayHints.get.exceptionHints.isSome and cnf.inlayHints.get.exceptionHints.get.enable.isSome:
    result = cnf.inlayHints.get.exceptionHints.get.enable.get

func parameterHintsEnabled*(cnf: NlsConfig): bool =
  result = true
  if cnf.inlayHints.isSome and cnf.inlayHints.get.parameterHints.isSome and cnf.inlayHints.get.parameterHints.get.enable.isSome:
    result = cnf.inlayHints.get.parameterHints.get.enable.get

func inlayHintsEnabled*(cnf: NlsConfig): bool =
  typeHintsEnabled(cnf) or exceptionHintsEnabled(cnf) or parameterHintsEnabled(cnf)

proc supportSignatureHelp*(cc: ClientCapabilities): bool = 
  if cc.isNil: return false
  let caps = cc.textDocument
  caps.isSome and caps.get.signatureHelp.isSome

proc getNimbleDumpInfo*(ls: LanguageServer, nimbleFile: string): NimbleDumpInfo =
  if nimbleFile in ls.nimDumpCache:
    return ls.nimDumpCache[nimbleFile]
  let info = execProcess("nimble dump " & nimbleFile)
  for line in info.splitLines:
    if line.startsWith("srcDir"):
      result.srcDir = line[(1 + line.find '"')..^2]
    if line.startsWith("name"):
      result.name = line[(1 + line.find '"')..^2]
    if line.startsWith("nimDir"):
      result.nimDir = some line[(1 + line.find '"')..^2]
    if line.startsWith("nimblePath"):
      result.nimblePath = some line[(1 + line.find '"')..^2]
    if line.startsWith("entryPoints"):
      result.entryPoints = line[(1 + line.find '"')..^2].split(',').mapIt(it.strip(chars = {' ', '"'}))
      
  var nimbleFile = nimbleFile
  if nimbleFile == "" and result.nimblePath.isSome:
    nimbleFile = result.nimblePath.get
  if nimbleFile != "":
    ls.nimDumpCache[nimbleFile] = result

proc parseWorkspaceConfiguration*(conf: JsonNode): NlsConfig =
  try:
    let nlsConfig: seq[NlsConfig] = (%conf).to(seq[NlsConfig])
    result = if nlsConfig.len > 0 and nlsConfig[0] != nil: nlsConfig[0] else: NlsConfig()
  except CatchableError:
    debug "Failed to parse the configuration.", error = getCurrentExceptionMsg()
    result = NlsConfig()

proc getWorkspaceConfiguration*(ls: LanguageServer): Future[NlsConfig] {.async.} =
  parseWorkspaceConfiguration(ls.workspaceConfiguration.await)

proc showMessage*(ls: LanguageServer, message: string, typ: MessageType) =  
  proc notify() =
    ls.connection.notify(
      "window/showMessage",
      %* {
         "type": typ.int,
         "message": message 
      })
  let verbosity = 
    ls
    .getWorkspaceConfiguration
    .waitFor
    .notificationVerbosity.get(NlsNotificationVerbosity.nvInfo)
  debug "ShowMessage ", message = message
  case verbosity:
  of nvInfo: 
    notify()
  of nvWarning:
    if typ.int <= MessageType.Warning.int :
       notify()
  of nvError:
    if typ == MessageType.Error: 
      notify()
  else: discard

proc getLspStatus*(ls: LanguageServer): NimLangServerStatus = 
  result.version = LSPVersion
  for projectFile, futNs in ls.projectFiles:
    let futNs = ls.projectFiles[projectFile]
    if futNs.finished:
      var ns: NimSuggest = futNs.read
      var nsStatus = NimSuggestStatus(
        projectFile: projectFile,
        capabilities: ns.capabilities.toSeq,
        version: ns.version,
        path: ns.nimsuggestPath,
        port: ns.port,
      )    
      result.nimsuggestInstances.add nsStatus
  
  for openFile in ls.openFiles.keys:
    let openFilePath = openFile.uriToPath
    result.openFiles.add openFilePath


proc sendStatusChanged*(ls: LanguageServer)  =
  let status = ls.getLspStatus()
  ls.connection.notify("extension/statusUpdate", %* status)


proc requiresDynamicRegistrationForDidChangeConfiguration(ls: LanguageServer): bool =
  ls.clientCapabilities.workspace.isSome and
  ls.clientCapabilities.workspace.get.didChangeConfiguration.isSome and
  ls.clientCapabilities.workspace.get.didChangeConfiguration.get.dynamicRegistration.get(false)

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
    result = (ae.enable == be.enable) and
            (ae.hintStringLeft == be.hintStringLeft) and
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
    result = inlayTypeHintsConfigurationEquals(a, b) and
             inlayExceptionHintsConfigurationEquals(a, b)

  if a.inlayHints.isSome and b.inlayHints.isSome:
    result = inlayHintsConfigurationEquals(a.inlayHints.get, b.inlayHints.get)
  else:
    result = a.inlayHints.isSome == b.inlayHints.isSome

proc getNimVersion(nimDir: string): string =
  let cmd = 
    if nimDir == "": "nim --version"
    else: nimDir / "nim --version"
  let info = execProcess(cmd)
  const NimCompilerVersion = "Nim Compiler Version "
  for line in info.splitLines:
    if line.startsWith(NimCompilerVersion):
      return line

proc getNimSuggestPathAndVersion(ls: LanguageServer, conf: NlsConfig, workingDir: string): (string, string) =
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
  while path.len > 0 and path != "/":
    let
      (dir, fname, ext) = path.splitFile()
      current = fname & ext
    if fileExists(path / current.addFileExt(".nim")) and certainty <= Folder:
      result = path / current.addFileExt(".nim")
      certainty = Folder
    if fileExists(path / current.addFileExt(".nim")) and
      (fileExists(path / current.addFileExt(".nim.cfg")) or
      fileExists(path / current.addFileExt(".nims"))) and certainty <= Cfg:
      result = path / current.addFileExt(".nim")
      certainty = Cfg
    if certainty <= Nimble:
      for nimble in walkFiles(path / "*.nimble"):
        let dumpInfo = ls.getNimbleDumpInfo(nimble)
        let name = dumpInfo.name
        let sourceDir = path / dumpInfo.srcDir
        let projectFile = sourceDir / (name & ".nim")
        if sourceDir.len != 0 and name.len != 0 and
            file.isRelativeTo(sourceDir) and fileExists(projectFile):
          debug "Found nimble project", projectFile = projectFile
          result = projectFile
          certainty = Nimble
          return
    if path == dir: break
    path = dir

proc getRootPath*(ip: InitializeParams): string =
  if ip.rootUri.isNone or ip.rootUri.get == "":
    if ip.rootPath.isSome and ip.rootPath.get != "":
      return ip.rootPath.get
    else:
      return getCurrentDir().pathToUri.uriToPath
  return ip.rootUri.get.uriToPath

proc getWorkingDir(ls: LanguageServer, path: string): Future[string] {.async.} =
  let
    rootPath = AbsoluteDir(ls.initializeParams.getRootPath)
    pathRelativeToRoot = string(AbsoluteFile(path).relativeTo(rootPath))
    mapping = ls.getWorkspaceConfiguration.await().workingDirectoryMapping.get(@[])

  result = getCurrentDir()

  for m in mapping:
    if m.projectFile == pathRelativeToRoot:
      result = rootPath.string / m.directory
      break;

proc progressSupported(ls: LanguageServer): bool =
  result = ls.initializeParams
    .capabilities
    .window
    .get(ClientCapabilities_window())
    .workDoneProgress
    .get(false)

proc progress*(ls: LanguageServer; token, kind: string, title = "") =
  if ls.progressSupported:
    ls.connection.notify(
      "$/progress",
      %* {
           "token": token,
           "value": {
             "kind": kind,
             "title": title
           }
      })

proc workDoneProgressCreate*(ls: LanguageServer, token: string) =
  if ls.progressSupported:
    discard ls.connection.call("window/workDoneProgress/create",
                               %ProgressParams(token: token))

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

proc getNimsuggest*(ls: LanguageServer, uri: string): Future[Nimsuggest] {.async, gcsafe.} 

proc uriStorageLocation*(ls: LanguageServer, uri: string): string =
  ls.storageDir / (hash(uri).toHex & ".nim")

proc uriToStash*(ls: LanguageServer, uri: string): string =
  if ls.openFiles.hasKey(uri) and ls.openFiles[uri].changed:
    uriStorageLocation(ls, uri)
  else:
    ""


proc range*(startLine, startCharacter, endLine, endCharacter: int): Range =
  return Range %* {
     "start": {
        "line": startLine,
        "character": startCharacter
     },
     "end": {
        "line": endLine,
        "character": endCharacter
     }
  }

proc toLabelRange*(suggest: Suggest): Range =
  with suggest:
    let endColumn = column + qualifiedPath[^1].strip(chars = {'`'}).len
    return range(line - 1, column, line - 1, endColumn)

proc toDiagnostic(suggest: Suggest): Diagnostic =
  with suggest:
    let
      endColumn = column + doc.rfind('\'') - doc.find('\'') - 2
      node = %* {
        "uri": pathToUri(filepath) ,
        "range": range(line - 1, column, line - 1, column + endColumn),
        "severity": case forth:
                      of "Error": DiagnosticSeverity.Error.int
                      of "Hint": DiagnosticSeverity.Hint.int
                      of "Warning": DiagnosticSeverity.Warning.int
                      else: DiagnosticSeverity.Error.int,
        "message": doc,
        "source": "nim",
        "code": "nimsuggest chk"
      }
    return node.to(Diagnostic)

proc sendDiagnostics*(ls: LanguageServer, diagnostics: seq[Suggest], path: string) =
  debug "Sending diagnostics", count = diagnostics.len, path = path
  let params = PublishDiagnosticsParams %* {
    "uri": pathToUri(path),
    "diagnostics": diagnostics.map(toDiagnostic)
  }
  ls.connection.notify("textDocument/publishDiagnostics", %params)

  if diagnostics.len != 0:
    ls.filesWithDiags.incl path
  else:
    ls.filesWithDiags.excl path

proc checkProject*(ls: LanguageServer, uri: string): Future[void] {.async, gcsafe.} =
  if not ls.getWorkspaceConfiguration.await().autoCheckProject.get(true):
    return
  debug "Running diagnostics", uri = uri
  let nimsuggest = ls.getNimsuggest(uri).await

  if nimsuggest.checkProjectInProgress:
    debug "Check project is already running", uri = uri
    nimsuggest.needsCheckProject = true
    return

  ls.cancelPendingFileChecks(nimsuggest)

  let token = fmt "Checking {uri}"
  ls.workDoneProgressCreate(token)
  ls.progress(token, "begin", fmt "Checking project {uri.uriToPath}")
  nimsuggest.checkProjectInProgress = true
  proc getFilepath(s: Suggest): string = s.filepath
  let
    diagnostics = nimsuggest.chk(uriToPath(uri), ls.uriToStash(uri))
      .await()
      .filter(sug => sug.filepath != "???")
    filesWithDiags = diagnostics.map(s => s.filepath).toHashSet

  ls.progress(token, "end")

  debug "Found diagnostics", file = filesWithDiags
  for (path, diags) in groupBy(diagnostics, getFilepath):
    ls.sendDiagnostics(diags, path)

  # clean files with no diags
  for path in ls.filesWithDiags:
    if not filesWithDiags.contains path:
      debug "Sending zero diags", path = path
      let params = PublishDiagnosticsParams %* {
        "uri": pathToUri(path),
        "diagnostics": @[]
      }
      ls.connection.notify("textDocument/publishDiagnostics", %params)
  ls.filesWithDiags = filesWithDiags
  nimsuggest.checkProjectInProgress = false

  if nimsuggest.needsCheckProject:
    nimsuggest.needsCheckProject = false
    callSoon() do () {.gcsafe.}:
      debug "Running delayed check project...", uri = uri
      traceAsyncErrors ls.checkProject(uri)

proc createOrRestartNimsuggest*(ls: LanguageServer, projectFile: string, uri = ""): void {.gcsafe.} =
  let
    configuration = ls.getWorkspaceConfiguration().waitFor()
    workingDir = ls.getWorkingDir(projectFile).waitFor()
    (nimsuggestPath, version) = ls.getNimSuggestPathAndVersion(configuration, workingDir)
    timeout = configuration.timeout.get(REQUEST_TIMEOUT)
    restartCallback = proc (ns: Nimsuggest) {.gcsafe.} =
      warn "Restarting the server due to requests being to slow", projectFile = projectFile
      ls.showMessage(fmt "Restarting nimsuggest for file {projectFile} due to timeout.",
                     MessageType.Warning)
      ls.createOrRestartNimsuggest(projectFile, uri)
      ls.sendStatusChanged()
    errorCallback = proc (ns: Nimsuggest) {.gcsafe.} =
      warn "Server stopped.", projectFile = projectFile
      if configuration.autoRestart.get(true) and ns.successfullCall:
        ls.createOrRestartNimsuggest(projectFile, uri)
      else:
        ls.showMessage(fmt "Server failed with {ns.errorMessage}.",
                       MessageType.Error)
      ls.sendStatusChanged()


    nimsuggestFut = createNimsuggest(projectFile, nimsuggestPath, version,
                                     timeout, restartCallback, errorCallback, workingDir, configuration.logNimsuggest.get(false),
                                     configuration.exceptionHintsEnabled)
    token = fmt "Creating nimsuggest for {projectFile}"

  ls.workDoneProgressCreate(token)

  if ls.projectFiles.hasKey(projectFile):
    var nimsuggestData = ls.projectFiles[projectFile]
    nimSuggestData.addCallback() do (fut: Future[Nimsuggest]) -> void:
      fut.read.stop()
    ls.projectFiles[projectFile] = nimsuggestFut
    ls.progress(token, "begin", fmt "Restarting nimsuggest for {projectFile}")
  else:
    ls.progress(token, "begin", fmt "Creating nimsuggest for {projectFile}")
    ls.projectFiles[projectFile] = nimsuggestFut

  nimsuggestFut.addCallback do (fut: Future[Nimsuggest]):
    if fut.read.failed:
      let msg = fut.read.errorMessage
      ls.showMessage(fmt "Nimsuggest initialization for {projectFile} failed with: {msg}",
                     MessageType.Error)
    else:
      ls.showMessage(fmt "Nimsuggest initialized for {projectFile}",
                     MessageType.Info)
      traceAsyncErrors ls.checkProject(uri)
      fut.read().openFiles.incl uri
    ls.progress(token, "end")
    ls.sendStatusChanged()

proc getNimsuggest*(ls: LanguageServer, uri: string): Future[Nimsuggest] {.async.} =
  let projectFile = await ls.openFiles[uri].projectFile
  if not ls.projectFiles.hasKey(projectFile):
    ls.createOrRestartNimsuggest(projectFile, uri)

  ls.lastNimsuggest = ls.projectFiles[projectFile]
  return await ls.projectFiles[projectFile]

proc restartAllNimsuggestInstances(ls: LanguageServer) =
  debug "Restarting all nimsuggest instances"
  for projectFile in ls.projectFiles.keys:
    ls.createOrRestartNimsuggest(projectFile, projectFile.pathToUri)

proc maybeRegisterCapabilityDidChangeConfiguration*(ls: LanguageServer) =
  if ls.requiresDynamicRegistrationForDidChangeConfiguration:
    let registrationParams = RegistrationParams(
      registrations: some(@[Registration(
        id: "a4606617-82c1-4e22-83db-0095fecb1093",
        `method`: "workspace/didChangeConfiguration"
      )])
    )
    ls.didChangeConfigurationRegistrationRequest = ls.connection.call(
      "client/registerCapability",
      %registrationParams)
    ls.didChangeConfigurationRegistrationRequest.addCallback() do (res: Future[JsonNode]):
      debug "Got response for the didChangeConfiguration registration:", res = res.read()

proc handleConfigurationChanges*(ls: LanguageServer, oldConfiguration, newConfiguration: NlsConfig) =
  if ls.clientCapabilities.workspace.isSome and
      ls.clientCapabilities.workspace.get.inlayHint.isSome and
      ls.clientCapabilities.workspace.get.inlayHint.get.refreshSupport.get(false) and
      not inlayHintsConfigurationEquals(oldConfiguration, newConfiguration):
    # toggling the exception hints triggers a full nimsuggest restart, since they are controlled by a nimsuggest command line option
    #   --exceptionInlayHints:on|off
    if not inlayExceptionHintsConfigurationEquals(oldConfiguration, newConfiguration):
      ls.restartAllNimsuggestInstances
    debug "Sending inlayHint refresh"
    ls.inlayHintsRefreshRequest = ls.connection.call("workspace/inlayHint/refresh",
                                                          newJNull())

proc maybeRequestConfigurationFromClient*(ls: LanguageServer) =
  if ls.supportsConfigurationRequest:
    debug "Requesting configuration from the client"
    let configurationParams = ConfigurationParams %* {"items": [{"section": "nim"}]}

    ls.prevWorkspaceConfiguration = ls.workspaceConfiguration

    ls.workspaceConfiguration =
      ls.connection.call("workspace/configuration",
                         %configurationParams)
    ls.workspaceConfiguration.addCallback() do (futConfiguration: Future[JsonNode]):
      if futConfiguration.error.isNil:
        debug "Received the following configuration", configuration = futConfiguration.read()
        if not isNil(ls.prevWorkspaceConfiguration) and ls.prevWorkspaceConfiguration.finished:
          let
            oldConfiguration = parseWorkspaceConfiguration(ls.prevWorkspaceConfiguration.read)
            newConfiguration = parseWorkspaceConfiguration(futConfiguration.read)
          handleConfigurationChanges(ls, oldConfiguration, newConfiguration)

  else:
    debug "Client does not support workspace/configuration"
    ls.workspaceConfiguration.complete(newJArray())

proc getCharacter*(ls: LanguageServer, uri: string, line: int, character: int): int =
  return ls.openFiles[uri].fingerTable[line].utf16to8(character)

proc stopNimsuggestProcesses*(ls: LanguageServer) {.async.} =
  if not ls.childNimsuggestProcessesStopped:
    debug "stopping child nimsuggest processes"
    ls.childNimsuggestProcessesStopped = true
    for ns in ls.projectFiles.values:
      let ns = await ns
      ns.stop()
  else:
    debug "child nimsuggest processes already stopped: CHECK!"

proc stopNimsuggestProcessesP*(ls: ptr LanguageServer) =
  waitFor stopNimsuggestProcesses(ls[])

proc getProjectFile*(fileUri: string, ls: LanguageServer): Future[string] {.async.} =
  let
    rootPath = AbsoluteDir(ls.initializeParams.getRootPath)
    pathRelativeToRoot = string(AbsoluteFile(fileUri).relativeTo(rootPath))
    mappings = ls.getWorkspaceConfiguration.await().projectMapping.get(@[])
  
  for mapping in mappings:
    if find(cstring(pathRelativeToRoot), re(mapping.fileRegex), 0, pathRelativeToRoot.len) != -1:
      result = string(rootPath) / mapping.projectFile
      trace "getProjectFile", project = result, uri = fileUri, matchedRegex = mapping.fileRegex
      return result
    else:
      trace "getProjectFile does not match", uri = fileUri, matchedRegex = mapping.fileRegex

  once: #once we refactor the project to chronos, we may move this code into init. Right now it hangs for some odd reason
    let rootPath = ls.initializeParams.getRootPath
    if rootPath != "":
      let nimbleFiles = walkFiles(rootPath / "*.nimble").toSeq
      if nimbleFiles.len > 0:
        let nimbleFile = nimbleFiles[0]
        let nimbleDumpInfo = ls.getNimbleDumpInfo(nimbleFile)
        ls.entryPoints = nimbleDumpInfo.getNimbleEntryPoints(ls.initializeParams.getRootPath)
        # ls.showMessage(fmt "Found entry point {ls.entryPoints}?", MessageType.Info)
        for entryPoint in ls.entryPoints:
          debug "Starting nimsuggest for entry point ", entry = entryPoint
          if entryPoint notin ls.projectFiles:
            ls.createOrRestartNimsuggest(entryPoint)

  result = ls.getProjectFileAutoGuess(fileUri)
  if result in ls.projectFiles:
    let ns = await ls.projectFiles[result]
    let isKnown = await ns.isKnown(fileUri)
    if ns.canHandleUnknown and not isKnown:
      debug "File is not known by nimsuggest", uri = fileUri, projectFile = result
      result = fileUri
  
  if result == "":
    result = fileUri

  debug "getProjectFile", project = result, fileUri = fileUri

proc warnIfUnknown*(ls: LanguageServer, ns: Nimsuggest, uri: string, projectFile: string):
     Future[void] {.async, gcsafe.} =
  let path = uri.uriToPath
  let isFileKnown = await ns.isKnown(path)
  if not isFileKnown and not ns.canHandleUnknown:
      ls.showMessage(fmt """{path} is not compiled as part of project {projectFile}.
  In orde to get the IDE features working you must either configure nim.projectMapping or import the module.""",
                    MessageType.Warning)

proc checkFile*(ls: LanguageServer, uri: string): Future[void] {.async.} =
  debug "Checking", uri = uri
  let token = fmt "Checking file {uri}"
  ls.workDoneProgressCreate(token)
  ls.progress(token, "begin", fmt "Checking {uri.uriToPath}")

  let
    path = uriToPath(uri)
    diagnostics = ls.getNimsuggest(uri)
      .await()
      .chkFile(path, ls.uriToStash(uri))
      .await()

  ls.progress(token, "end")

  ls.sendDiagnostics(diagnostics, path)