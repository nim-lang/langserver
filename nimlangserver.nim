import macros, strformat, faststreams/async_backend,
  faststreams/asynctools_adapters, faststreams/inputs, faststreams/outputs,
  json_rpc/streamconnection, json_rpc/server, os, sugar, sequtils, hashes, osproc,
  suggestapi, protocol/enums, protocol/types, with, tables, strutils, sets,
  ./utils, ./pipes, chronicles, std/re, uri, "$nim/compiler/pathutils",
  asyncprocmonitor, std/strscans, json_serialization, serialization/formats,
  std/json, std/parseutils

when defined(posix):
  import posix

const
  RESTART_COMMAND = "nimlangserver.restart"
  RECOMPILE_COMMAND = "nimlangserver.recompile"
  CHECK_PROJECT_COMMAND = "nimlangserver.checkProject"
  FILE_CHECK_DELAY = 1000

type
  NlsNimsuggestConfig = ref object of RootObj
    projectFile: string
    fileRegex: string

  NlsWorkingDirectoryMaping = ref object of RootObj
    projectFile: string
    directory: string

  NlsInlayTypeHintsConfig = ref object of RootObj
    enable*: Option[bool]

  NlsInlayExceptionHintsConfig = ref object of RootObj
    enable*: Option[bool]
    hintStringLeft*: Option[string]
    hintStringRight*: Option[string]

  NlsInlayHintsConfig = ref object of RootObj
    typeHints*: Option[NlsInlayTypeHintsConfig]
    exceptionHints*: Option[NlsInlayExceptionHintsConfig]

  NlsConfig = ref object of RootObj
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

  FileInfo = ref object of RootObj
    projectFile: Future[string]
    changed: bool
    fingerTable: seq[seq[tuple[u16pos, offset: int]]]
    cancelFileCheck: Future[void]
    checkInProgress: bool
    needsChecking: bool

  CommandLineParams* = object
    clientProcessId: Option[int]

  LanguageServer* = ref object
    clientCapabilities*: ClientCapabilities
    initializeParams*: InitializeParams
    connection: StreamConnection
    projectFiles: Table[string, Future[Nimsuggest]]
    openFiles: Table[string, FileInfo]
    cancelFutures: Table[int, Future[void]]
    workspaceConfiguration: Future[JsonNode]
    inlayHintsRefreshRequest: Future[JsonNode]
    filesWithDiags: HashSet[string]
    lastNimsuggest: Future[Nimsuggest]
    childNimsuggestProcessesStopped*: bool
    isShutdown*: bool
    storageDir*: string
    cmdLineClientProcessId: Option[int]

  Certainty = enum
    None,
    Folder,
    Cfg,
    Nimble

createJsonFlavor(LSPFlavour, omitOptionalFields = true)
Option.useDefaultSerializationIn LSPFlavour

macro `%*`*(t: untyped, inputStream: untyped): untyped =
  result = newCall(bindSym("to", brOpen),
                   newCall(bindSym("%*", brOpen), inputStream), t)

proc partial*[A, B, C] (fn: proc(a: A, b: B): C {.gcsafe.}, a: A):
    proc (b: B) : C {.gcsafe, raises: [Defect, CatchableError, Exception].} =
  return
    proc(b: B): C {.gcsafe, raises: [Defect, CatchableError, Exception].} =
      return fn(a, b)

proc partial*[A, B, C] (fn: proc(a: A, b: B, id: int): C {.gcsafe.}, a: A):
    proc (b: B, id: int) : C {.gcsafe, raises: [Defect, CatchableError, Exception].} =
  return
    proc(b: B, id: int): C {.gcsafe, raises: [Defect, CatchableError, Exception].} =
      return fn(a, b, id)

proc supportSignatureHelp(cc: ClientCapabilities): bool = 
  if cc.isNil: return false
  let caps = cc.textDocument
  caps.isSome and caps.get.signatureHelp.isSome

proc getProjectFileAutoGuess(fileUri: string): string =
  let file = fileUri.decodeUrl
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
        let info = execProcess("nimble dump " & nimble)
        var sourceDir, name: string
        for line in info.splitLines:
          if line.startsWith("srcDir"):
            sourceDir = path / line[(1 + line.find '"')..^2]
          if line.startsWith("name"):
            name = line[(1 + line.find '"')..^2]
        let projectFile = sourceDir / (name & ".nim")
        if sourceDir.len != 0 and name.len != 0 and
            file.isRelativeTo(sourceDir) and fileExists(projectFile):
          debug "Found nimble project", projectFile = projectFile
          result = projectFile
          certainty = Nimble
    if path == dir: break
    path = dir

proc parseWorkspaceConfiguration(conf: JsonNode): NlsConfig =
  try:
    let nlsConfig: seq[NlsConfig] = (%conf).to(seq[NlsConfig])
    result = if nlsConfig.len > 0 and nlsConfig[0] != nil: nlsConfig[0] else: NlsConfig()
  except CatchableError:
    debug "Failed to parse the configuration."
    result = NlsConfig()

proc getWorkspaceConfiguration(ls: LanguageServer): Future[NlsConfig] {.async.} =
  parseWorkspaceConfiguration(ls.workspaceConfiguration.await)

proc getRootPath(ip: InitializeParams): string =
  if ip.rootUri == "":
    return getCurrentDir().pathToUri.uriToPath
  return ip.rootUri.uriToPath

proc getProjectFile(fileUri: string, ls: LanguageServer): Future[string] {.async.} =
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

  result = getProjectFileAutoGuess(fileUri)
  debug "getProjectFile", project = result

proc showMessage(ls: LanguageServer, message: string, typ: MessageType) =
  ls.connection.notify(
    "window/showMessage",
    %* {
         "type": typ.int,
         "message": message
    })

# Fixes callback clobbering in core implementation
proc `or`*[T, Y](fut1: Future[T], fut2: Future[Y]): Future[void] =
  var retFuture = newFuture[void]("asyncdispatch.`or`")
  proc cb[X](fut: Future[X]) =
    if not retFuture.finished:
      if fut.failed: retFuture.fail(fut.error)
      else: retFuture.complete()
  fut1.addCallback(cb[T])
  fut2.addCallback(cb[Y])
  return retFuture

proc getCharacter(ls: LanguageServer, uri: string, line: int, character: int): int =
  return ls.openFiles[uri].fingerTable[line].utf16to8(character)

proc stopNimsuggestProcesses(ls: LanguageServer) {.async.} =
  if not ls.childNimsuggestProcessesStopped:
    debug "stopping child nimsuggest processes"
    ls.childNimsuggestProcessesStopped = true
    for ns in ls.projectFiles.values:
      let ns = await ns
      ns.stop()
  else:
    debug "child nimsuggest processes already stopped: CHECK!"

proc stopNimsuggestProcessesP(ls: ptr LanguageServer) =
  waitFor stopNimsuggestProcesses(ls[])

proc initialize(p: tuple[ls: LanguageServer, pipeInput: AsyncInputStream], params: InitializeParams):
    Future[InitializeResult] {.async.} =

  proc onClientProcessExitAsync(): Future[void] {.async.} =
    debug "onClientProcessExitAsync"
    await p.ls.stopNimsuggestProcesses
    p.pipeInput.close()

  proc onClientProcessExit(fd: AsyncFD): bool =
    debug "onClientProcessExit"
    waitFor onClientProcessExitAsync()
    result = true

  debug "Initialize received..."
  if params.processId.isSome:
    let pid = params.processId.get
    if pid.kind == JInt:
      debug "Registering monitor for process ", pid=pid.num
      var pidInt = int(pid.num)
      if p.ls.cmdLineClientProcessId.isSome:
        if p.ls.cmdLineClientProcessId.get == pidInt:
          debug "Process ID already specified in command line, no need to register monitor again"
        else:
          debug "Warning! Client Process ID in initialize request differs from the one, specified in the command line. This means the client violates the LSP spec!"
          debug "Will monitor both process IDs..."
          hookAsyncProcMonitor(pidInt, onClientProcessExit)
      else:
        hookAsyncProcMonitor(pidInt, onClientProcessExit)
  p.ls.initializeParams = params
  p.ls.clientCapabilities = params.capabilities
  result = InitializeResult(
    capabilities: ServerCapabilities(
      textDocumentSync: some(%TextDocumentSyncOptions(
        openClose: some(true),
        change: some(TextDocumentSyncKind.Full.int),
        willSave: some(false),
        willSaveWaitUntil: some(false),
        save: some(SaveOptions(includeText: some(true))))
      ),
      hoverProvider: some(true),
      workspace: some(ServerCapabilities_workspace(
        workspaceFolders: some(WorkspaceFoldersServerCapabilities())
      )),
      completionProvider: CompletionOptions(
        triggerCharacters: some(@["."]),
        resolveProvider: some(false)
      ),
      signatureHelpProvider: SignatureHelpOptions(
        triggerCharacters: some(@["(", ","])
      ),
      definitionProvider: some(true),
      declarationProvider: some(true),
      typeDefinitionProvider: some(true),
      referencesProvider: some(true),
      documentHighlightProvider: some(true),
      workspaceSymbolProvider: some(true),
      executeCommandProvider: some(ExecuteCommandOptions(
        commands: some(@[RESTART_COMMAND, RECOMPILE_COMMAND, CHECK_PROJECT_COMMAND])
      )),
      inlayHintProvider: some(InlayHintOptions(
        resolveProvider: some(false)
      )),
      documentSymbolProvider: some(true),
      codeActionProvider: some(true)
    )
  )  
  # Support rename by default, but check if we can also support prepare
  result.capabilities.renameProvider = %true
  if params.capabilities.textDocument.isSome:
    let docCaps = params.capabilities.textDocument.unsafeGet()
    # Check if the client support prepareRename
    #TODO do the test on the action
    if docCaps.rename.isSome and docCaps.rename.get().prepareSupport.get(false):
      result.capabilities.renameProvider = %* {
        "prepareProvider": true
      }

proc initialized(ls: LanguageServer, _: JsonNode):
    Future[void] {.async.} =
  debug "Client initialized."
  let workspaceCap = ls.initializeParams.capabilities.workspace
  if workspaceCap.isSome and workspaceCap.get.configuration.get(false):
     debug "Requesting configuration from the client"
     let configurationParams = ConfigurationParams %* {"items": [{"section": "nim"}]}

     ls.workspaceConfiguration =
       ls.connection.call("workspace/configuration",
                          %configurationParams)
     ls.workspaceConfiguration.addCallback() do (futConfiguration: Future[JsonNode]):
       if futConfiguration.error.isNil:
         debug "Received the following configuration", configuration = futConfiguration.read()
  else:
    debug "Client does not support workspace/configuration"
    ls.workspaceConfiguration.complete(newJArray())

proc orCancelled[T](fut: Future[T], ls: LanguageServer, id: int): Future[T] {.async.} =
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

proc cancelRequest(ls: LanguageServer, params: CancelParams):
    Future[void] {.async.} =
  if params.id.isSome:
    let
      id = params.id.get.getInt
      cancelFuture = ls.cancelFutures.getOrDefault id

    debug "Cancelling: ", id = id
    if not cancelFuture.isNil:
      cancelFuture.complete()

proc uriStorageLocation(ls: LanguageServer, uri: string): string =
  ls.storageDir / (hash(uri).toHex & ".nim")

proc uriToStash(ls: LanguageServer, uri: string): string =
  if ls.openFiles.hasKey(uri) and ls.openFiles[uri].changed:
    uriStorageLocation(ls, uri)
  else:
    ""

proc createOrRestartNimsuggest(ls: LanguageServer, projectFile: string, uri = ""): void {.gcsafe.}

proc getNimsuggest(ls: LanguageServer, uri: string): Future[Nimsuggest] {.async.} =
  let projectFile = await ls.openFiles[uri].projectFile
  if not ls.projectFiles.hasKey(projectFile):
    ls.createOrRestartNimsuggest(projectFile, uri)
  ls.lastNimsuggest = ls.projectFiles[projectFile]
  return await ls.projectFiles[projectFile]

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

proc toLabelRange(suggest: Suggest): Range =
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

proc progressSupported(ls: LanguageServer): bool =
  result = ls.initializeParams
    .capabilities
    .window
    .get(ClientCapabilities_window())
    .workDoneProgress
    .get(false)

proc progress(ls: LanguageServer; token, kind: string, title = "") =
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

proc workDoneProgressCreate(ls: LanguageServer, token: string) =
  if ls.progressSupported:
    discard ls.connection.call("window/workDoneProgress/create",
                               %ProgressParams(token: token))

proc sendDiagnostics(ls: LanguageServer, diagnostics: seq[Suggest], path: string) =
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

proc checkFile(ls: LanguageServer, uri: string): Future[void] {.async.} =
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

proc cancelPendingFileChecks(ls: LanguageServer, nimsuggest: Nimsuggest) =
  # stop all checks on file level if we are going to run checks on project
  # level.
  for uri in nimsuggest.openFiles:
    let fileData = ls.openFiles[uri]
    if fileData != nil:
      let cancelFileCheck = fileData.cancelFileCheck
      if cancelFileCheck != nil and not cancelFileCheck.finished:
        cancelFileCheck.complete()
      fileData.needsChecking = false

proc checkProject(ls: LanguageServer, uri: string): Future[void] {.async, gcsafe.} =
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


proc createOrRestartNimsuggest(ls: LanguageServer, projectFile: string, uri = ""): void {.gcsafe.} =
  let
    configuration = ls.getWorkspaceConfiguration().waitFor()
    nimsuggestPath = configuration.nimsuggestPath.get("nimsuggest")
    workingDir = ls.getWorkingDir(projectFile).waitFor()
    timeout = configuration.timeout.get(REQUEST_TIMEOUT)
    restartCallback = proc (ns: Nimsuggest) {.gcsafe.} =
      warn "Restarting the server due to requests being to slow", projectFile = projectFile
      ls.showMessage(fmt "Restarting nimsuggest for file {projectFile} due to timeout.",
                     MessageType.Warning)
      ls.createOrRestartNimsuggest(projectFile, uri)
    errorCallback = proc (ns: Nimsuggest) {.gcsafe.} =
      warn "Server stopped.", projectFile = projectFile
      if configuration.autoRestart.get(true) and ns.successfullCall:
        ls.createOrRestartNimsuggest(projectFile, uri)
      else:
        ls.showMessage(fmt "Server failed with {ns.errorMessage}.",
                       MessageType.Error)

    nimsuggestFut = createNimsuggest(projectFile, nimsuggestPath,
                                     timeout, restartCallback, errorCallback, workingDir, configuration.logNimsuggest.get(false))
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

proc warnIfUnknown(ls: LanguageServer, ns: Nimsuggest, uri: string, projectFile: string):
     Future[void] {.async, gcsafe.} =
  let path = uri.uriToPath
  let sug = await ns.known(path)
  if sug[0].forth == "false":
    ls.showMessage(fmt """{path} is not compiled as part of project {projectFile}.
In orde to get the IDE features working you must either configure nim.projectMapping or import the module.""",
                   MessageType.Warning)

proc didOpen(ls: LanguageServer, params: DidOpenTextDocumentParams):
    Future[void] {.async, gcsafe.} =
  with params.textDocument:
    debug "New document opened for URI:", uri = uri
    let
      file = open(ls.uriStorageLocation(uri), fmWrite)
      projectFileFuture = getProjectFile(uriToPath(uri), ls)

    ls.openFiles[uri] = FileInfo(
      projectFile: projectFileFuture,
      changed: false,
      fingerTable: @[])

    let projectFile = await projectFileFuture

    debug "Document associated with the following projectFile", uri = uri, projectFile = projectFile
    if not ls.projectFiles.hasKey(projectFile):
      ls.createOrRestartNimsuggest(projectFile, uri)

    for line in text.splitLines:
      ls.openFiles[uri].fingerTable.add line.createUTFMapping()
      file.writeLine line
    file.close()

    ls.getNimsuggest(uri).addCallback() do (fut: Future[Nimsuggest]) -> void:
      if not fut.failed:
        discard ls.warnIfUnknown(fut.read, uri, projectFile)

proc scheduleFileCheck(ls: LanguageServer, uri: string) {.gcsafe.} =
  if not ls.getWorkspaceConfiguration().waitFor().autoCheckFile.get(true):
    return

  # schedule file check after the file is modified
  let fileData = ls.openFiles[uri]
  if fileData.cancelFileCheck != nil and not fileData.cancelFileCheck.finished:
    fileData.cancelFileCheck.complete()

  if fileData.checkInProgress:
    fileData.needsChecking = true
    return

  var cancelFuture = newFuture[void]()
  fileData.cancelFileCheck = cancelFuture

  sleepAsync(FILE_CHECK_DELAY).addCallback() do ():
    if not cancelFuture.finished:
      fileData.checkInProgress = true
      ls.checkFile(uri).addCallback() do() {.gcsafe.}:
        ls.openFiles[uri].checkInProgress = false
        if fileData.needsChecking:
          fileData.needsChecking = false
          ls.scheduleFileCheck(uri)

proc didChange(ls: LanguageServer, params: DidChangeTextDocumentParams):
    Future[void] {.async, gcsafe.} =
   with params:
     let
       uri = textDocument.uri
       file = open(ls.uriStorageLocation(uri), fmWrite)

     ls.openFiles[uri].fingerTable = @[]
     ls.openFiles[uri].changed = true
     for line in contentChanges[0].text.splitLines:
       ls.openFiles[uri].fingerTable.add line.createUTFMapping()
       file.writeLine line
     file.close()

     ls.scheduleFileCheck(uri)

proc didSave(ls: LanguageServer, params: DidSaveTextDocumentParams):
    Future[void] {.async, gcsafe.} =
  let
    uri = params.textDocument.uri
    nimsuggest = ls.getNimsuggest(uri).await()
  ls.openFiles[uri].changed = false
  traceAsyncErrors nimsuggest.changed(uriToPath(uri))

  if ls.getWorkspaceConfiguration().await().checkOnSave.get(true):
    debug "Checking project", uri = uri
    traceAsyncErrors ls.checkProject(uri)

proc didClose(ls: LanguageServer, params: DidCloseTextDocumentParams):
    Future[void] {.async, gcsafe.} =
  let uri =  params.textDocument.uri
  debug "Closed the following document:", uri = uri

  if ls.openFiles[uri].changed:
    # check the file if it is closed but not saved.
    traceAsyncErrors ls.checkFile(uri)

  ls.openFiles.del uri

proc toMarkedStrings(suggest: Suggest): seq[MarkedStringOption] =
  var label = suggest.qualifiedPath.join(".")
  if suggest.forth != "":
    label &= ": " & suggest.forth

  result = @[
    MarkedStringOption %* {
       "language": "nim",
       "value": label
    }
  ]

  if suggest.doc != "":
    result.add MarkedStringOption %* {
       "language": "markdown",
       "value": suggest.doc
    }

proc hover(ls: LanguageServer, params: HoverParams, id: int):
    Future[Option[Hover]] {.async.} =
  with (params.position, params.textDocument):
    let
      nimsuggest = await ls.getNimsuggest(uri)
      suggestions = await nimsuggest
       .def(uriToPath(uri),
            ls.uriToStash(uri),
            line + 1,
            ls.getCharacter(uri, line, character))
       .orCancelled(ls, id)
    if suggestions.len == 0:
      return none[Hover]();
    else:
      return some(Hover(contents: some(%toMarkedStrings(suggestions[0]))))

proc toLocation(suggest: Suggest): Location =
  return Location %* {
    "uri": pathToUri(suggest.filepath),
    "range": toLabelRange(suggest)
  }

proc definition(ls: LanguageServer, params: TextDocumentPositionParams, id: int):
    Future[seq[Location]] {.async.} =
  with (params.position, params.textDocument):
    result = ls.getNimsuggest(uri)
      .await()
      .def(uriToPath(uri),
           ls.uriToStash(uri),
           line + 1,
           ls.getCharacter(uri, line, character))
      .orCancelled(ls, id)
      .await()
      .map(toLocation)

proc declaration(ls: LanguageServer, params: TextDocumentPositionParams, id: int):
    Future[seq[Location]] {.async.} =
  with (params.position, params.textDocument):
    result = ls.getNimsuggest(uri)
      .await()
      .declaration(uriToPath(uri),
           ls.uriToStash(uri),
           line + 1,
           ls.getCharacter(uri, line, character))
      .orCancelled(ls, id)
      .await()
      .map(toLocation)

proc expandAll(ls: LanguageServer, params: TextDocumentPositionParams):
    Future[ExpandResult] {.async.} =
  with (params.position, params.textDocument):
    let expand = ls.getNimsuggest(uri)
      .await()
      .expand(uriToPath(uri),
           ls.uriToStash(uri),
           line + 1,
           ls.getCharacter(uri, line, character))
      .await()

proc createRangeFromSuggest(suggest: Suggest): Range =
  result = range(suggest.line - 1,
                 0,
                 suggest.endLine - 1,
                 suggest.endCol)

proc fixIdentation(s: string, indent: int): string =
  result = s.split("\n")
    .mapIt(if (it != ""):
             repeat(" ", indent) & it
           else:
             it)
    .join("\n")

proc expand(ls: LanguageServer, params: ExpandTextDocumentPositionParams):
    Future[ExpandResult] {.async} =
  with (params, params.position, params.textDocument):
    let
      lvl = level.get(-1)
      tag = if lvl == -1: "all" else: $lvl
      expand = ls.getNimsuggest(uri)
        .await()
        .expand(uriToPath(uri),
             ls.uriToStash(uri),
             line + 1,
             ls.getCharacter(uri, line, character),
             fmt "  {tag}")
        .await()
    if expand.len != 0:
      result = ExpandResult(content: expand[0].doc.fixIdentation(character),
                            range: expand[0].createRangeFromSuggest())

proc typeDefinition(ls: LanguageServer, params: TextDocumentPositionParams, id: int):
    Future[seq[Location]] {.async.} =
  with (params.position, params.textDocument):
    result = ls.getNimsuggest(uri)
      .await()
      .`type`(uriToPath(uri),
              ls.uriToStash(uri),
              line + 1,
              ls.getCharacter(uri, line, character))
      .orCancelled(ls, id)
      .await()
      .map(toLocation)

proc references(ls: LanguageServer, params: ReferenceParams):
    Future[seq[Location]] {.async.} =
  with (params.position, params.textDocument, params.context):
    let
      nimsuggest = await ls.getNimsuggest(uri)
      refs = await nimsuggest
      .use(uriToPath(uri),
           ls.uriToStash(uri),
           line + 1,
           ls.getCharacter(uri, line, character))
    result = refs
      .filter(suggest => suggest.section != ideDef or includeDeclaration)
      .map(toLocation);

proc prepareRename(ls: LanguageServer, params: PrepareRenameParams,
                   id: int): Future[JsonNode] {.async.} =
  with (params.position, params.textDocument):
    let
      nimsuggest = await ls.getNimsuggest(uri)
      def = await nimsuggest.def(
        uriToPath(uri),
        ls.uriToStash(uri),
        line + 1,
        ls.getCharacter(uri, line, character)
      )
    if def.len == 0:
      return newJNull()
    # Check if the symbol belongs to the project
    let projectDir = ls.initializeParams.getRootPath
    if def[0].filePath.isRelativeTo(projectDir):
      return %def[0].toLocation().range

    return newJNull()

proc rename(ls: LanguageServer, params: RenameParams, id: int): Future[WorkspaceEdit] {.async.} =
  # We reuse the references command as to not duplicate it
  let references = await ls.references(ReferenceParams(
    context: ReferenceContext(includeDeclaration: true),
    textDocument: params.textDocument,
    position: params.position
  ))
  # Build up list of edits that the client needs to perform for each file
  let projectDir = ls.initializeParams.getRootPath
  var edits = newJObject()
  for reference in references:
    # Only rename symbols in the project.
    # If client supports prepareRename then an error will already have been thrown
    if reference.uri.uriToPath().isRelativeTo(projectDir):
      if reference.uri notin edits:
        edits[reference.uri] = newJArray()
      edits[reference.uri] &= %TextEdit(range: reference.range, newText: params.newName)
  result = WorkspaceEdit(changes: some edits)

proc convertInlayHintKind(kind: SuggestInlayHintKind): InlayHintKind_int =
  case kind
  of sihkType:
    result = 1
  of sihkParameter:
    result = 2
  of sihkException:
    # LSP doesn't have an exception inlay hint type, so we pretend (i.e. lie) that it is a type hint.
    result = 1

proc toInlayHint(suggest: SuggestInlayHint; configuration: NlsConfig): InlayHint =
  let hint_line = suggest.line - 1
  # TODO: how to convert column?
  var hint_col = suggest.column
  result = InlayHint(
    position: Position(
      line: hint_line,
      character: hint_col
    ),
    label: suggest.label,
    kind: some(convertInlayHintKind(suggest.kind)),
    paddingLeft: some(suggest.paddingLeft),
    paddingRight: some(suggest.paddingRight)
  )
  if suggest.kind == sihkException and suggest.label == "try " and configuration.inlayHints.isSome and configuration.inlayHints.get.exceptionHints.isSome and configuration.inlayHints.get.exceptionHints.get.hintStringLeft.isSome:
    result.label = configuration.inlayHints.get.exceptionHints.get.hintStringLeft.get
  if suggest.kind == sihkException and suggest.label == "!" and configuration.inlayHints.isSome and configuration.inlayHints.get.exceptionHints.isSome and configuration.inlayHints.get.exceptionHints.get.hintStringRight.isSome:
    result.label = configuration.inlayHints.get.exceptionHints.get.hintStringRight.get
  if suggest.tooltip != "":
    result.tooltip = some(suggest.tooltip)
  else:
    result.tooltip = some("")
  if suggest.allowInsert:
    result.textEdits = some(@[
      TextEdit(
        newText: suggest.label,
        `range`: Range(
          start: Position(
            line: hint_line,
            character: hint_col
          ),
          `end`: Position(
            line: hint_line,
            character: hint_col
          )
        )
      )
    ])

func typeHintsEnabled(cnf: NlsConfig): bool =
  result = true
  if cnf.inlayHints.isSome and cnf.inlayHints.get.typeHints.isSome and cnf.inlayHints.get.typeHints.get.enable.isSome:
    result = cnf.inlayHints.get.typeHints.get.enable.get

func exceptionHintsEnabled(cnf: NlsConfig): bool =
  result = true
  if cnf.inlayHints.isSome and cnf.inlayHints.get.exceptionHints.isSome and cnf.inlayHints.get.exceptionHints.get.enable.isSome:
    result = cnf.inlayHints.get.exceptionHints.get.enable.get

func inlayHintsEnabled(cnf: NlsConfig): bool =
  typeHintsEnabled(cnf) or exceptionHintsEnabled(cnf)

proc inlayHint(ls: LanguageServer, params: InlayHintParams, id: int): Future[seq[InlayHint]] {.async.} =
  debug "inlayHint received..."
  with (params.range, params.textDocument):
    let
      configuration = ls.getWorkspaceConfiguration.await()
      nimsuggest = await ls.getNimsuggest(uri)
    if nimsuggest.protocolVersion < 4 or not configuration.inlayHintsEnabled:
      return @[]
    let
      suggestions = await nimsuggest
        .inlayHints(uriToPath(uri),
                    ls.uriToStash(uri),
                    start.line + 1,
                    ls.getCharacter(uri, start.line, start.character),
                    `end`.line + 1,
                    ls.getCharacter(uri, `end`.line, `end`.character),
                    " +exceptionHints")
        .orCancelled(ls, id)
    result = suggestions
      .filter(x => ((x.inlayHintInfo.kind == sihkType) and configuration.typeHintsEnabled) or
                   ((x.inlayHintInfo.kind == sihkException) and configuration.exceptionHintsEnabled))
      .map(x => x.inlayHintInfo.toInlayHint(configuration))
      .filter(x => x.label != "")

proc codeAction(ls: LanguageServer, params: CodeActionParams):
    Future[seq[CodeAction]] {.async.} =
  let projectUri = await getProjectFile(params.textDocument.uri.uriToPath, ls)
  return seq[CodeAction] %* [{
    "title": "Clean build",
    "kind": "source",
    "command": {
      "title": "Clean build",
      "command": RECOMPILE_COMMAND,
      "arguments": @[projectUri]
    }
  }, {
    "title": "Refresh project errors",
    "kind": "source",
    "command": {
      "title": "Refresh project errors",
      "command": CHECK_PROJECT_COMMAND,
      "arguments": @[projectUri]
    }
  }, {
    "title": "Restart nimsuggest",
    "kind": "source",
    "command": {
      "title": "Restart nimsuggest",
      "command": RESTART_COMMAND,
      "arguments": @[projectUri]
    }
  }]

proc executeCommand(ls: LanguageServer, params: ExecuteCommandParams):
    Future[JsonNode] {.async.} =
  let projectFile = params.arguments[0].getStr
  case params.command:
  of RESTART_COMMAND:
    debug "Restarting nimsuggest", projectFile = projectFile
    ls.createOrRestartNimsuggest(projectFile, projectFile.pathToUri)
  of CHECK_PROJECT_COMMAND:
    debug "Checking project", projectFile = projectFile
    ls.checkProject(projectFile.pathToUri).traceAsyncErrors
  of RECOMPILE_COMMAND:
    debug "Clean build", projectFile = projectFile
    let
      token = fmt "Compiling {projectFile}"
      ns = ls.projectFiles.getOrDefault(projectFile)
    if ns != nil:
      ls.workDoneProgressCreate(token)
      ls.progress(token, "begin", fmt "Compiling project {projectFile}")
      ns.await()
        .recompile()
        .addCallback() do ():
          ls.progress(token, "end")
          ls.checkProject(projectFile.pathToUri).traceAsyncErrors

  result = newJNull()

proc toCompletionItem(suggest: Suggest): CompletionItem =
  with suggest:
    return CompletionItem %* {
      "label": qualifiedPath[^1].strip(chars = {'`'}),
      "kind": nimSymToLSPKind(suggest).int,
      "documentation": doc,
      "detail": nimSymDetails(suggest),
    }

proc completion(ls: LanguageServer, params: CompletionParams, id: int):
    Future[seq[CompletionItem]] {.async.} =
  with (params.position, params.textDocument):
    let
      nimsuggest = await ls.getNimsuggest(uri)
      completions = await nimsuggest
                            .sug(uriToPath(uri),
                                 ls.uriToStash(uri),
                                 line + 1,
                                 ls.getCharacter(uri, line, character))
                            .orCancelled(ls, id)
    result = completions.map(toCompletionItem)

    if ls.clientCapabilities.supportSignatureHelp() and nsCon in nimSuggest.capabilities:
      #show only unique overloads if we support signatureHelp
      var unique = initTable[string, CompletionItem]()
      for completion in result:
        if completion.label notin unique:
          unique[completion.label] = completion
      result = unique.values.toSeq     

proc toSignatureInformation(suggest: Suggest): SignatureInformation = 
  var fnKind, strParams: string
  var params = newSeq[ParameterInformation]()
  #TODO handle params. Ideally they are handled in the compiler but as fallback we could handle them as follows
  #notice we will need to also handle the  ',' and the back and forths between the client and the server
  if scanf(suggest.forth, "$*($*)", fnKind, strParams):
    for param in strParams.split(","):
      params.add(ParameterInformation(label: param))

  let name = suggest.qualifiedPath[^1].strip(chars = {'`'})
  let detail = suggest.forth.split(" ")
  var label = name
  if detail.len > 1:
    label = &"{fnKind} {name}({strParams})"
  return SignatureInformation %* {
    "label": label,
    "documentation": suggest.doc,
    "parameters": newSeq[ParameterInformation](), #notice params is not used
    }


proc signatureHelp(ls: LanguageServer, params: SignatureHelpParams, id: int): 
  Future[Option[SignatureHelp]] {.async.} = 
    #TODO handle prev signature
    # if params.context.activeSignatureHelp.isSome:
    #   let prevSignature = params.context.activeSignatureHelp.get.signatures.get[params.context.activeSignatureHelp.get.activeSignature.get]
    #   debug "prevSignature ", prevSignature = $prevSignature.label
    # else:
    #   debug "no prevSignature"
    #only support signatureHelp if the client supports it
    # if docCaps.signatureHelp.isSome and docCaps.signatureHelp.get.contextSupport.get(false):    
    #   result.capabilities.signatureHelpProvider = SignatureHelpOptions(
    #           triggerCharacters: some(@["(", ","])
    #   )
    if not ls.clientCapabilities.supportSignatureHelp():
    #Some clients doesnt support signatureHelp
      return none[SignatureHelp]()
    with (params.position, params.textDocument):
      let nimsuggest = await ls.getNimsuggest(uri)
      if nsCon notin nimSuggest.capabilities:
        #support signatureHelp only if the current version of NimSuggest supports it. 
        return none[SignatureHelp]()

      let completions = await nimsuggest
                              .con(uriToPath(uri),                              
                                  ls.uriToStash(uri),
                                  line + 1,
                                  ls.getCharacter(uri, line, character))
                              .orCancelled(ls, id)
      let signatures = completions.map(toSignatureInformation);
      if signatures.len() > 0:
        return some SignatureHelp(
          signatures: some(signatures),
          activeSignature: some(0),
          activeParameter: some(0)
        )
      else: 
        return none[SignatureHelp]()

proc toSymbolInformation(suggest: Suggest): SymbolInformation =
  with suggest:
    return SymbolInformation %* {
      "location": toLocation(suggest),
      "kind": nimSymToLSPSymbolKind(suggest.symKind).int,
      "name": suggest.name
    }

proc documentSymbols(ls: LanguageServer, params: DocumentSymbolParams, id: int):
    Future[seq[SymbolInformation]] {.async.} =
  let uri = params.textDocument.uri
  result = ls.getNimsuggest(uri)
    .await()
    .outline(uriToPath(uri), ls.uriToStash(uri))
    .orCancelled(ls, id)
    .await()
    .map(toSymbolInformation)

proc workspaceSymbol(ls: LanguageServer, params: WorkspaceSymbolParams, id: int):
    Future[seq[SymbolInformation]] {.async.} =
  if ls.lastNimsuggest != nil:
    let
      nimsuggest = await ls.lastNimsuggest
      symbols = await nimsuggest
                        .globalSymbols(params.query, "-")
                        .orCancelled(ls, id)
    return symbols.map(toSymbolInformation);

proc toDocumentHighlight(suggest: Suggest): DocumentHighlight =
  return DocumentHighlight %* {
    "range": toLabelRange(suggest)
  }

proc documentHighlight(ls: LanguageServer, params: TextDocumentPositionParams, id: int):
    Future[seq[DocumentHighlight]] {.async.} =

  with (params.position, params.textDocument):
    let
      nimsuggest = await ls.getNimsuggest(uri)
      suggestLocations = await nimsuggest.highlight(uriToPath(uri),
                                ls.uriToStash(uri),
                                line + 1,
                                ls.getCharacter(uri, line, character))
                             .orCancelled(ls, id)
    result = suggestLocations.map(toDocumentHighlight);

proc extractId  (id: JsonNode): int =
  if id.kind == JInt:
    result = id.getInt
  if id.kind == JString:
    discard parseInt(id.getStr, result)

proc shutdown(ls: LanguageServer, input: JsonNode): Future[RpcResult] {.async, gcsafe, raises: [Defect, CatchableError, Exception].} =
  debug "Shutting down"
  await ls.stopNimsuggestProcesses()
  ls.isShutdown = true
  let id = input{"id"}.extractId
  result = some(StringOfJson("null"))
  trace "Shutdown complete"

proc exit(p: tuple[ls: LanguageServer, pipeInput: AsyncInputStream], _: JsonNode):
    Future[RpcResult] {.async, gcsafe, raises: [Defect, CatchableError, Exception].} =
  if not p.ls.isShutdown:
    debug "Received an exit request without prior shutdown request"
    await p.ls.stopNimsuggestProcesses()
  debug "Quitting process"
  result = none[StringOfJson]()
  p.pipeInput.close()

proc inlayHintsConfigurationEquals(a, b: NlsConfig): bool =

  proc inlayTypeHintsConfigurationEquals(a, b: NlsInlayHintsConfig): bool =
    if a.typeHints.isSome and b.typeHints.isSome:
      result = a.typeHints.get.enable == b.typeHints.get.enable
    else:
      result = a.typeHints.isSome == b.typeHints.isSome

  proc inlayExceptionHintsConfigurationEquals(a, b: NlsInlayHintsConfig): bool =
    if a.exceptionHints.isSome and b.exceptionHints.isSome:
      let
        ae = a.exceptionHints.get
        be = b.exceptionHints.get
      result = (ae.enable == be.enable) and
              (ae.hintStringLeft == be.hintStringLeft) and
              (ae.hintStringRight == be.hintStringRight)
    else:
      result = a.exceptionHints.isSome == b.exceptionHints.isSome

  proc inlayHintsConfigurationEquals(a, b: NlsInlayHintsConfig): bool =
    result = inlayTypeHintsConfigurationEquals(a, b) and
             inlayExceptionHintsConfigurationEquals(a, b)

  if a.inlayHints.isSome and b.inlayHints.isSome:
    result = inlayHintsConfigurationEquals(a.inlayHints.get, b.inlayHints.get)
  else:
    result = a.inlayHints.isSome == b.inlayHints.isSome

proc didChangeConfiguration(ls: LanguageServer, conf: JsonNode):
    Future[void] {.async, gcsafe.} =
  debug "Changed configuration: ", conf = conf

  if ls.workspaceConfiguration.finished:
    let
      oldConfiguration = parseWorkspaceConfiguration(ls.workspaceConfiguration.read)
      newConfiguration = parseWorkspaceConfiguration(conf)
    ls.workspaceConfiguration = newFuture[JsonNode]()
    ls.workspaceConfiguration.complete(conf)
    if ls.clientCapabilities.workspace.isSome and
       ls.clientCapabilities.workspace.get.inlayHint.isSome and
       ls.clientCapabilities.workspace.get.inlayHint.get.refreshSupport.get(false) and
       not inlayHintsConfigurationEquals(oldConfiguration, newConfiguration):
      debug "Sending inlayHint refresh"
      ls.inlayHintsRefreshRequest = ls.connection.call("workspace/inlayHint/refresh",
                                                       newJNull())

proc setTrace(ls: LanguageServer, params: SetTraceParams) {.async.} =
  debug "setTrace", value = params.value

proc registerHandlers*(connection: StreamConnection,
                       pipeInput: AsyncInputStream,
                       storageDir: string,
                       cmdLineParams: CommandLineParams): LanguageServer =
  let ls = LanguageServer(
    connection: connection,
    workspaceConfiguration: Future[JsonNode](),
    projectFiles: initTable[string, Future[Nimsuggest]](),
    cancelFutures: initTable[int, Future[void]](),
    filesWithDiags: initHashSet[string](),
    openFiles: initTable[string, FileInfo](),
    storageDir: storageDir,
    cmdLineClientProcessId: cmdLineParams.clientProcessId)
  result = ls

  connection.register("initialize", partial(initialize, (ls: ls, pipeInput: pipeInput)))
  connection.register("textDocument/completion", partial(completion, ls))
  connection.register("textDocument/definition", partial(definition, ls))
  connection.register("textDocument/declaration", partial(declaration, ls))
  connection.register("textDocument/typeDefinition", partial(typeDefinition, ls))
  connection.register("textDocument/documentSymbol", partial(documentSymbols, ls))
  connection.register("textDocument/hover", partial(hover, ls))
  connection.register("textDocument/references", partial(references, ls))
  connection.register("textDocument/codeAction", partial(codeAction, ls))
  connection.register("textDocument/prepareRename", partial(prepareRename, ls))
  connection.register("textDocument/rename", partial(rename, ls))
  connection.register("textDocument/inlayHint", partial(inlayHint, ls))
  connection.register("textDocument/signatureHelp", partial(signatureHelp, ls))
  connection.register("workspace/executeCommand", partial(executeCommand, ls))
  connection.register("workspace/symbol", partial(workspaceSymbol, ls))
  connection.register("textDocument/documentHighlight", partial(documentHighlight, ls))
  connection.register("extension/macroExpand", partial(expand, ls))
  connection.register("shutdown", partial(shutdown, ls))
  connection.register("exit", partial(exit, (ls: ls, pipeInput: pipeInput)))

  connection.registerNotification("$/cancelRequest", partial(cancelRequest, ls))
  connection.registerNotification("initialized", partial(initialized, ls))
  connection.registerNotification("textDocument/didChange", partial(didChange, ls))
  connection.registerNotification("textDocument/didOpen", partial(didOpen, ls))
  connection.registerNotification("textDocument/didSave", partial(didSave, ls))
  connection.registerNotification("textDocument/didClose", partial(didClose, ls))
  connection.registerNotification("workspace/didChangeConfiguration", partial(didChangeConfiguration, ls))
  connection.registerNotification("$/setTrace", partial(setTrace, ls))

proc ensureStorageDir*: string =
  result = getTempDir() / "nimlangserver"
  discard existsOrCreateDir(result)

var
  # global var, only used in the signal handlers (for stopping the child nimsuggest
  # processes during an abnormal program termination)
  globalLS: ptr LanguageServer

when isMainModule:

  proc getVersionFromNimble(): string = 
    const content = staticRead("nimlangserver.nimble")
    for v in content.splitLines:
      if v.startsWith("version"):
        return v.split("=")[^1].strip(chars = {' ', '"'})
    return "unknown"

  proc handleParams(): CommandLineParams =
    if paramCount() > 0 and paramStr(1) in ["-v", "--version"]:
      const version = getVersionFromNimble()
      echo version
      quit()
    var i = 1
    while i <= paramCount():
      var para = paramStr(i)
      if para.startsWith("--clientProcessId="):
        var pidStr = para.substr(18)
        try:
          var pid = pidStr.parseInt
          result.clientProcessId = some(pid)
        except ValueError:
          stderr.writeLine("Invalid client process ID: ", pidStr)
          quit 1
      inc i

  proc main =
    try:
      let cmdLineParams = handleParams() 
      let storageDir = ensureStorageDir()
      var
        pipe = createPipe(register = true, nonBlockingWrite = false)
        stdioThread: Thread[tuple[pipe: AsyncPipe, file: File]]

      createThread(stdioThread, copyFileToPipe, (pipe: pipe, file: stdin))

      let
        connection = StreamConnection.new(Async(fileOutput(stdout, allowAsyncOps = true)))
        pipeInput = asyncPipeInput(pipe)
      var
        ls = registerHandlers(connection, pipeInput, storageDir, cmdLineParams)

      globalLS = addr ls

      if cmdLineParams.clientProcessId.isSome:
        debug "Registering monitor for process id, specified on command line", clientProcessId=cmdLineParams.clientProcessId.get

        proc onCmdLineClientProcessExitAsync(): Future[void] {.async.} =
          debug "onCmdLineClientProcessExitAsync"
          await ls.stopNimsuggestProcesses
          pipeInput.close()

        proc onCmdLineClientProcessExit(fd: AsyncFD): bool =
          debug "onCmdLineClientProcessExit"
          waitFor onCmdLineClientProcessExitAsync()
          result = true

        hookAsyncProcMonitor(cmdLineParams.clientProcessId.get, onCmdLineClientProcessExit)

      when defined(posix):
        onSignal(SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE):
          debug "Terminated via signal", sig
          globalLS.stopNimsuggestProcessesP()
          exitnow(1)

      waitFor connection.start(pipeInput)
      debug "exiting main thread", isShutdown=ls.isShutdown
      quit(if ls.isShutdown: 0 else: 1)
    except Exception as ex:
      debug "Shutting down due to an error: ", msg = ex.msg
      debug "Stack trace: ", stack_trace = ex.getStackTrace()
      stderr.writeLine("Shutting down due to an error: ", ex.msg)
      stderr.writeLine(ex.getStackTrace())
      quit 1

  main()
