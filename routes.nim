import macros, strformat, chronos,
  json_rpc/server, os, sugar, sequtils,
  suggestapi, protocol/enums, protocol/types, with, tables, strutils,
  ./utils, chronicles,
  asyncprocmonitor, std/strscans, json_serialization,
  std/json, std/parseutils, ls


#routes
proc initialize*(p: tuple[ls: LanguageServer, onExit: OnExitCallback], params: InitializeParams):
    Future[InitializeResult] {.async.} =

  proc onClientProcessExitAsync(): Future[void] {.async:(raises: [Exception]).} =    
      debug "onClientProcessExitAsync"      
      await p.ls.stopNimsuggestProcesses
      await p.onExit()
    
  proc onClientProcessExit() {.closure, gcsafe, raises: [].} =
    {.cast(raises: []).}:
      try:
        debug "onClientProcessExit"
        waitFor onClientProcessExitAsync()
      except:
        discard

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
  debug "Initialize completed. Trying to start nimsuggest instances"
  #If we are in a nimble project here, we try to start the entry points

proc toCompletionItem(suggest: Suggest): CompletionItem =
  with suggest:
    return CompletionItem %* {
      "label": qualifiedPath[^1].strip(chars = {'`'}),
      "kind": nimSymToLSPKind(suggest).int,
      "documentation": doc,
      "detail": nimSymDetails(suggest),
    }

proc completion*(ls: LanguageServer, params: CompletionParams, id: int):
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

proc toLocation*(suggest: Suggest): Location =
  return Location %* {
    "uri": pathToUri(suggest.filepath),
    "range": toLabelRange(suggest)
  }

proc definition*(ls: LanguageServer, params: TextDocumentPositionParams, id: int):
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

proc declaration*(ls: LanguageServer, params: TextDocumentPositionParams, id: int):
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

proc expandAll*(ls: LanguageServer, params: TextDocumentPositionParams):
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

proc expand*(ls: LanguageServer, params: ExpandTextDocumentPositionParams):
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

proc status*(ls: LanguageServer, params: NimLangServerStatusParams): Future[NimLangServerStatus] {.async.} =
  debug "Received status request"
  ls.getLspStatus()

proc typeDefinition*(ls: LanguageServer, params: TextDocumentPositionParams, id: int):
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

proc toSymbolInformation*(suggest: Suggest): SymbolInformation =
  with suggest:
    return SymbolInformation %* {
      "location": toLocation(suggest),
      "kind": nimSymToLSPSymbolKind(suggest.symKind).int,
      "name": suggest.name
    }

proc documentSymbols*(ls: LanguageServer, params: DocumentSymbolParams, id: int):
    Future[seq[SymbolInformation]] {.async.} =
  let uri = params.textDocument.uri
  result = ls.getNimsuggest(uri)
    .await()
    .outline(uriToPath(uri), ls.uriToStash(uri))
    .orCancelled(ls, id)
    .await()
    .map(toSymbolInformation)

proc scheduleFileCheck(ls: LanguageServer, uri: string) {.gcsafe, raises: [].} =
  if not ls.getWorkspaceConfiguration().waitFor().autoCheckFile.get(true):
    return

  # schedule file check after the file is modified
  let fileData = ls.openFiles.getOrDefault(uri)
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
      ls.checkFile(uri).addCallback() do() {.gcsafe, raises:[].}:
        try:
          ls.openFiles[uri].checkInProgress = false
          if fileData.needsChecking:
            fileData.needsChecking = false
            ls.scheduleFileCheck(uri)
        except KeyError:
          discard 
        # except Exception:
        #   discard


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

proc hover*(ls: LanguageServer, params: HoverParams, id: int):
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

proc references*(ls: LanguageServer, params: ReferenceParams):
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

proc prepareRename*(ls: LanguageServer, params: PrepareRenameParams,
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
    if def[0].filePath.isRelTo(projectDir):
      return %def[0].toLocation().range

    return newJNull()

proc rename*(ls: LanguageServer, params: RenameParams, id: int): Future[WorkspaceEdit] {.async.} =
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
    if reference.uri.uriToPath().isRelTo(projectDir):
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

proc inlayHint*(ls: LanguageServer, params: InlayHintParams, id: int): Future[seq[InlayHint]] {.async.} =
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
                    " +exceptionHints +parameterHints")
        .orCancelled(ls, id)
    result = suggestions
      .filter(x => ((x.inlayHintInfo.kind == sihkType) and configuration.typeHintsEnabled) or
                   ((x.inlayHintInfo.kind == sihkException) and configuration.exceptionHintsEnabled) or
                   ((x.inlayHintInfo.kind == sihkParameter) and configuration.parameterHintsEnabled))
      .map(x => x.inlayHintInfo.toInlayHint(configuration))
      .filter(x => x.label != "")

proc codeAction*(ls: LanguageServer, params: CodeActionParams):
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

proc executeCommand*(ls: LanguageServer, params: ExecuteCommandParams):
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

proc signatureHelp*(ls: LanguageServer, params: SignatureHelpParams, id: int):
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

proc workspaceSymbol*(ls: LanguageServer, params: WorkspaceSymbolParams, id: int):
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

proc documentHighlight*(ls: LanguageServer, params: TextDocumentPositionParams, id: int):
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

proc shutdown*(ls: LanguageServer, input: JsonNode): Future[JsonNode] {.async, gcsafe, raises: [Defect, CatchableError, Exception].} =
  debug "Shutting down"
  await ls.stopNimsuggestProcesses()
  ls.isShutdown = true
  let id = input{"id"}.extractId
  result = newJNull()
  trace "Shutdown complete"

proc exit*(p: tuple[ls: LanguageServer, onExit: OnExitCallback], _: JsonNode):
    Future[JsonNode] {.async, gcsafe, raises: [Defect, CatchableError, Exception].} =
  if not p.ls.isShutdown:
    debug "Received an exit request without prior shutdown request"
    await p.ls.stopNimsuggestProcesses()
  debug "Quitting process"
  result = newJNull()
  await p.onExit()

#Notifications
proc initialized*(ls: LanguageServer, _: JsonNode):
    Future[void] {.async.} =
  debug "Client initialized."
  maybeRegisterCapabilityDidChangeConfiguration(ls)
  maybeRequestConfigurationFromClient(ls)

proc cancelRequest*(ls: LanguageServer, params: CancelParams):
    Future[void] {.async.} =
  if params.id.isSome:
    let
      id = params.id.get.getInt
      cancelFuture = ls.cancelFutures.getOrDefault id

    debug "Cancelling: ", id = id
    if not cancelFuture.isNil:
      cancelFuture.complete()

proc setTrace*(ls: LanguageServer, params: SetTraceParams) {.async.} =
  debug "setTrace", value = params.value

proc didChange*(ls: LanguageServer, params: DidChangeTextDocumentParams):
    Future[void] {.async, gcsafe.} =
   with params:
      let
        uri = textDocument.uri
        file = open(ls.uriStorageLocation(uri), fmWrite)

      ls.openFiles[uri].fingerTable = @[]
      ls.openFiles[uri].changed = true
      if contentChanges.len <= 0:
        file.close()
        return
      for line in contentChanges[0].text.splitLines:
        ls.openFiles[uri].fingerTable.add line.createUTFMapping()
        file.writeLine line
      file.close()

      ls.scheduleFileCheck(uri)

proc didSave*(ls: LanguageServer, params: DidSaveTextDocumentParams):
    Future[void] {.async, gcsafe.} =
  let
    uri = params.textDocument.uri
    nimsuggest = ls.getNimsuggest(uri).await()
  ls.openFiles[uri].changed = false
  traceAsyncErrors nimsuggest.changed(uriToPath(uri))

  if ls.getWorkspaceConfiguration().await().checkOnSave.get(true):
    debug "Checking project", uri = uri
    traceAsyncErrors ls.checkProject(uri)

  var toStop = newTable[string, Nimsuggest]()
  #We first get the project file for the current file so we can test if this file recently imported another project
  let thisProjectFile = await getProjectFile(uri.uriToPath, ls)
  let ns = await ls.projectFiles[thisProjectFile]
  if ns.canHandleUnknown:
    for projectFile in ls.projectFiles.keys:
      if projectFile in ls.entryPoints: continue
      let isKnown = await ns.isKnown(projectFile)
      if isKnown:
        toStop[projectFile] = await ls.projectFiles[projectFile]

    for projectFile, ns in toStop:
      ns.stop()
      ls.projectFiles.del projectFile
    if toStop.len > 0:
      ls.sendStatusChanged()

proc didClose*(ls: LanguageServer, params: DidCloseTextDocumentParams):
    Future[void] {.async, gcsafe.} =
  let uri =  params.textDocument.uri
  debug "Closed the following document:", uri = uri

  if ls.openFiles[uri].changed:
    # check the file if it is closed but not saved.
    traceAsyncErrors ls.checkFile(uri)

  ls.openFiles.del uri

proc didOpen*(ls: LanguageServer, params: DidOpenTextDocumentParams):
    Future[void] {.async, gcsafe.} =
  with params.textDocument:
    debug "New document opened for URI:", uri = uri
    let
      file = open(ls.uriStorageLocation(uri), fmWrite)
      projectFileFuture = getProjectFile(uriToPath(uri), ls)

    ls.openFiles[uri] = NlsFileInfo(
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

    let projectFileUri = projectFile.pathToUri
    if projectFileUri notin ls.openFiles:
      var params = params
      params.textDocument.uri = projectFileUri
      await didOpen(ls, params)

      debug "Opening project file", uri = projectFile, file = uri

proc didChangeConfiguration*(ls: LanguageServer, conf: JsonNode):
    Future[void] {.async, gcsafe.} =
  debug "Changed configuration: ", conf = conf

  if ls.usePullConfigurationModel:
    ls.maybeRequestConfigurationFromClient
  else:
    if ls.workspaceConfiguration.finished:
      let
        oldConfiguration = parseWorkspaceConfiguration(ls.workspaceConfiguration.read)
        newConfiguration = parseWorkspaceConfiguration(conf)
      ls.workspaceConfiguration = newFuture[JsonNode]()
      ls.workspaceConfiguration.complete(conf)
      handleConfigurationChanges(ls, oldConfiguration, newConfiguration)
