import macros, strformat, faststreams/async_backend, itertools,
  faststreams/asynctools_adapters, faststreams/inputs, faststreams/outputs,
  json_rpc/streamconnection, os, sugar, sequtils, hashes, osproc,
  suggestapi, protocol/enums, protocol/types, with, tables, strutils, sets,
  ./utils, ./pipes, chronicles, std/re, uri, "$nim/compiler/pathutils"

const
  STORAGE = getTempDir() / "nimlangserver"
  RESTART_COMMAND = "nimlangserver.restart"
  RECOMPILE_COMMAND = "nimlangserver.recompile"
  CHECK_PROJECT_COMMAND = "nimlangserver.checkProject"
  FILE_CHECK_DELAY = 1000

discard existsOrCreateDir(STORAGE)

type
  NlsNimsuggestConfig = ref object of RootObj
    projectFile: string
    fileRegex: string

  NlsConfig = ref object of RootObj
    projectMapping*: OptionalSeq[NlsNimsuggestConfig]
    checkOnSave*: Option[bool]
    nimsuggestPath*: Option[string]
    timeout*: Option[int]

  FileInfo = ref object of RootObj
    projectFile: Future[string]
    changed: bool
    fingerTable: seq[seq[tuple[u16pos, offset: int]]]
    cancelFileCheck: Future[void]
    checkInProgress: bool
    needsChecking: bool

  LanguageServer* = ref object
    clientCapabilities*: ClientCapabilities
    initializeParams*: InitializeParams
    connection: StreamConnection
    projectFiles: Table[string, Future[Nimsuggest]]
    openFiles: Table[string, FileInfo]
    cancelFutures: Table[int, Future[void]]
    workspaceConfiguration: Future[JsonNode]
    filesWithDiags: HashSet[string]
    lastNimsuggest: Future[Nimsuggest]

  Certainty = enum
    None,
    Folder,
    Cfg,
    Nimble

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

proc getProjectFileAutoGuess(fileUri: string): string =
  let file = fileUri.decodeUrl
  result = file
  let (dir, _, _) = result.splitFile()
  var
    path = dir
    certainty = None
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
    path = dir

proc getWorkspaceConfiguration(ls: LanguageServer): Future[NlsConfig] {.async} =
  try:
    let nlsConfig: seq[NlsConfig] =
      (%await ls.workspaceConfiguration).to(seq[NlsConfig])
    result = if nlsConfig.len > 0: nlsConfig[0] else: NlsConfig()
  except CatchableError:
    debug "Failed to parse the configuration."
    result = NlsConfig()

proc getProjectFile(fileUri: string, ls: LanguageServer): Future[string] {.async} =
  let
    rootPath = AbsoluteDir(ls.initializeParams.rootUri.uriToPath)
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

proc initialize(ls: LanguageServer, params: InitializeParams):
    Future[InitializeResult] {.async} =
  debug "Initialize received..."
  ls.initializeParams = params
  return InitializeResult(
    capabilities: ServerCapabilities(
      textDocumentSync: some(%TextDocumentSyncOptions(
        openClose: some(true),
        change: some(TextDocumentSyncKind.Full.int),
        willSave: some(false),
        willSaveWaitUntil: some(false),
        save: some(SaveOptions(includeText: some(true))))),
      hoverProvider: some(true),
      workspace: WorkspaceCapability(
        workspaceFolders: some(WorkspaceFolderCapability())),
      completionProvider: CompletionOptions(
        triggerCharacters: some(@["."]),
        resolveProvider: some(false)),
      definitionProvider: some(true),
      referencesProvider: some(true),
      documentHighlightProvider: some(true),
      workspaceSymbolProvider: some(true),
      executeCommandProvider: ExecuteCommandOptions(
        commands: some(@[RESTART_COMMAND, RECOMPILE_COMMAND, CHECK_PROJECT_COMMAND])),
      documentSymbolProvider: some(true),
      codeActionProvider: some(true)))

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
    Future[void] {.async} =
  let
    id = params.id.getInt
    cancelFuture = ls.cancelFutures.getOrDefault id

  debug "Cancelling: ", id = id
  if not cancelFuture.isNil:
    cancelFuture.complete()

proc uriToStash(uri: string): string =
  STORAGE / (hash(uri).toHex & ".nim")

proc uriToStash(ls: LanguageServer, uri: string): string =
  if ls.openFiles[uri].changed:
    result = uriToStash(uri)
  else:
    result = ""

proc getNimsuggest(ls: LanguageServer, uri: string): Future[Nimsuggest] {.async.} =
  let projectFile = await ls.openFiles[uri].projectFile
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
    .get(WindowCapabilities())
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

proc checkProject(ls: LanguageServer, uri: string): Future[void] {.async.} =
  debug "Running diagnostics", uri = uri
  let nimsuggest = ls.getNimsuggest(uri).await

  if nimsuggest.checkProjectInProgress:
    debug "Check project is already running", uri = uri
    nimsuggest.needsCheckProject = true
    return

  ls.cancelPendingFileChecks(nimsuggest)

  let token = fmt "Checking {uri}"
  ls.workDoneProgressCreate(token)
  ls.progress(token, "begin", fmt "Building project {uri.uriToPath}")
  nimsuggest.checkProjectInProgress = true
  let
    diagnostics = nimsuggest.chk(uriToPath(uri), ls.uriToStash(uri))
      .await()
      .filter(sug => sug.filepath != "???")
    filesWithDiags = diagnostics.map(s => s.filepath).toHashSet

  ls.progress(token, "end")

  debug "Found diagnostics", file = filesWithDiags
  for (path, diags) in groupBy(diagnostics, s => s.filepath):
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
    callSoon() do ():
      debug "Running delayed check project...", uri = uri
      traceAsyncErrors ls.checkProject(uri)

proc createOrRestartNimsuggest(ls: LanguageServer, projectFile: string, uri = ""): void =
  let
    configuration = ls.getWorkspaceConfiguration().waitFor()
    nimsuggestPath = configuration.nimsuggestPath.get("nimsuggest")
    timeout = configuration.timeout.get(REQUEST_TIMEOUT)
    restartCallback = proc (ns: Nimsuggest) =
      warn "Restarting the server due to requests being to slow", projectFile = projectFile
      ls.showMessage(fmt "Restarting nimsuggest for file {projectFile} due to timeout.",
                     MessageType.Warning)
      ls.createOrRestartNimsuggest(projectFile, uri)
    errorCallback = proc (ns: Nimsuggest) =
      warn "Server stopped.", projectFile = projectFile
      ls.showMessage(fmt "Server failed with {ns.errorMessage} due to timeout.",
                     MessageType.Error)
    nimsuggestFut = createNimsuggest(projectFile, nimsuggestPath,
                                     timeout, restartCallback, errorCallback)
    token = fmt "Creating nimsuggest for {projectFile}"

  if ls.projectFiles.hasKey(projectFile):
    var nimsuggestData = ls.projectFiles[projectFile]
    nimSuggestData.addCallback() do (fut: Future[Nimsuggest]) -> void:
      fut.read.stop()
    ls.projectFiles[projectFile] = nimsuggestFut
    ls.progress(token, "begin", fmt "Restarting nimsuggest for {projectFile}")
  else:
    ls.progress(token, "begin", fmt "Creating nimsuggest for {projectFile}")
    ls.projectFiles[projectFile] = nimsuggestFut

  ls.workDoneProgressCreate(token)

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
      file = open(uriToStash(uri), fmWrite)
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

proc scheduleFileCheck(ls: LanguageServer, uri: string) =
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
      ls.checkFile(uri).addCallback() do():
        ls.openFiles[uri].checkInProgress = false
        if fileData.needsChecking:
          fileData.needsChecking = false
          ls.scheduleFileCheck(uri)

proc didChange(ls: LanguageServer, params: DidChangeTextDocumentParams):
    Future[void] {.async, gcsafe.} =
   with params:
     let
       uri = textDocument.uri
       file = open(uriToStash(uri), fmWrite)

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
    Future[Option[Hover]] {.async} =
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
    Future[seq[Location]] {.async} =
  with (params.position, params.textDocument):
    let
      nimsuggest = await ls.getNimsuggest(uri)
      suggestLocations = await nimsuggest.def(uriToPath(uri),
                                ls.uriToStash(uri),
                                line + 1,
                                ls.getCharacter(uri, line, character))
                             .orCancelled(ls, id)
    result = suggestLocations.map(toLocation);

proc references(ls: LanguageServer, params: ReferenceParams):
    Future[seq[Location]] {.async} =
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

proc codeAction(ls: LanguageServer, params: CodeActionParams):
    Future[seq[CodeAction]] {.async} =
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
    Future[JsonNode] {.async} =
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
    let token = fmt "Compiling {projectFile}"
    ls.workDoneProgressCreate(token)
    ls.progress(token, "begin", fmt "Compiling project {projectFile}")
    ls.getNimsuggest(projectFile.pathToUri)
      .await()
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
      "detail": nimSymDetails(suggest)
    }

proc completion(ls: LanguageServer, params: CompletionParams, id: int):
    Future[seq[CompletionItem]] {.async} =
  with (params.position, params.textDocument):
    let
      nimsuggest = await ls.getNimsuggest(uri)
      completions = await nimsuggest
                            .sug(uriToPath(uri),
                                 ls.uriToStash(uri),
                                 line + 1,
                                 ls.getCharacter(uri, line, character))
                            .orCancelled(ls, id)
    return completions.map(toCompletionItem);

proc toSymbolInformation(suggest: Suggest): SymbolInformation =
  with suggest:
    return SymbolInformation %* {
      "location": toLocation(suggest),
      "kind": nimSymToLSPSymbolKind(suggest.symKind).int,
      "name": suggest.name
    }

proc documentSymbols(ls: LanguageServer, params: DocumentSymbolParams, id: int):
    Future[seq[SymbolInformation]] {.async} =
  let uri = params.textDocument.uri
  result = ls.getNimsuggest(uri)
    .await()
    .outline(uriToPath(uri), ls.uriToStash(uri))
    .orCancelled(ls, id)
    .await()
    .map(toSymbolInformation)

proc workspaceSymbol(ls: LanguageServer, params: WorkspaceSymbolParams, id: int):
    Future[seq[SymbolInformation]] {.async} =
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
    Future[seq[DocumentHighlight]] {.async} =

  with (params.position, params.textDocument):
    let
      nimsuggest = await ls.getNimsuggest(uri)
      suggestLocations = await nimsuggest.highlight(uriToPath(uri),
                                ls.uriToStash(uri),
                                line + 1,
                                ls.getCharacter(uri, line, character))
                             .orCancelled(ls, id)
    result = suggestLocations.map(toDocumentHighlight);


proc registerHandlers*(connection: StreamConnection) =
  let ls = LanguageServer(
    connection: connection,
    workspaceConfiguration: Future[JsonNode](),
    projectFiles: initTable[string, Future[Nimsuggest]](),
    cancelFutures: initTable[int, Future[void]](),
    filesWithDiags: initHashSet[string](),
    openFiles: initTable[string, FileInfo]())
  connection.register("initialize", partial(initialize, ls))
  connection.register("textDocument/completion", partial(completion, ls))
  connection.register("textDocument/definition", partial(definition, ls))
  connection.register("textDocument/documentSymbol", partial(documentSymbols, ls))
  connection.register("textDocument/hover", partial(hover, ls))
  connection.register("textDocument/references", partial(references, ls))
  connection.register("textDocument/codeAction", partial(codeAction, ls))
  connection.register("workspace/executeCommand", partial(executeCommand, ls))
  connection.register("workspace/symbol", partial(workspaceSymbol, ls))
  connection.register("textDocument/documentHighlight", partial(documentHighlight, ls))

  connection.registerNotification("$/cancelRequest", partial(cancelRequest, ls))
  connection.registerNotification("initialized", partial(initialized, ls))
  connection.registerNotification("textDocument/didChange", partial(didChange, ls))
  connection.registerNotification("textDocument/didOpen", partial(didOpen, ls))
  connection.registerNotification("textDocument/didSave", partial(didSave, ls))
  connection.registerNotification("textDocument/didClose", partial(didClose, ls))

when isMainModule:
  var
    pipe = createPipe(register = true, nonBlockingWrite = false)
    stdioThread: Thread[tuple[pipe: AsyncPipe, file: File]]

  createThread(stdioThread, copyFileToPipe, (pipe: pipe, file: stdin))

  let connection = StreamConnection.new(Async(fileOutput(stdout, allowAsyncOps = true)));
  registerHandlers(connection)
  waitFor connection.start(asyncPipeInput(pipe))
