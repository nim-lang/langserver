import
  strformat,
  chronos,
  chronos/asyncproc,
  json_rpc/server,
  os,
  sugar,
  sequtils,
  suggestapi,
  protocol/enums,
  protocol/types,
  with,
  tables,
  strutils,
  ./utils,
  chronicles,
  asyncprocmonitor,
  json_serialization,
  std/[strscans, times, json, parseutils, strutils],
  ls,
  regex,
  stew/[byteutils],
  nimexpand,
  testrunner
  
import macros except error

proc getNphPath(): Option[string] =
  let path = findExe "nph"
  if path == "":
    none(string)
  else:
    some path

#routes
proc initialize*(
    p: tuple[ls: LanguageServer, onExit: OnExitCallback], params: InitializeParams
): Future[InitializeResult] {.async.} =
  proc onClientProcessExitAsync(): Future[void] {.async.} =
    debug "onClientProcessExitAsync"
    await p.ls.stopNimsuggestProcesses
    await p.onExit()

  proc onClientProcessExit() {.closure, gcsafe.} =
    try:
      debug "onClientProcessExit"
      waitFor onClientProcessExitAsync()
    except Exception:
      error "Error in onClientProcessExit ", msg = getCurrentExceptionMsg()

  debug "Initialize received..."
  if params.processId.isSome:
    let pid = params.processId.get
    if pid.kind == JInt:
      debug "Registering monitor for process ", pid = pid.num
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
      textDocumentSync: some(
        %TextDocumentSyncOptions(
          openClose: some(true),
          change: some(TextDocumentSyncKind.Full.int),
          willSave: some(false),
          willSaveWaitUntil: some(true),
          save: some(SaveOptions(includeText: some(true))),
        )
      ),
      hoverProvider: some(true),
      workspace: some(
        ServerCapabilities_workspace(
          workspaceFolders: some(WorkspaceFoldersServerCapabilities())
        )
      ),
      completionProvider:
        CompletionOptions(triggerCharacters: some(@["."]), resolveProvider: some(false)),
      signatureHelpProvider: SignatureHelpOptions(triggerCharacters: some(@["(", ","])),
      definitionProvider: some(true),
      declarationProvider: some(true),
      typeDefinitionProvider: some(true),
      referencesProvider: some(true),
      documentHighlightProvider: some(true),
      workspaceSymbolProvider: some(true),
      executeCommandProvider: some(
        ExecuteCommandOptions(
          commands: some(@[RESTART_COMMAND, RECOMPILE_COMMAND, CHECK_PROJECT_COMMAND])
        )
      ),
      inlayHintProvider: some(InlayHintOptions(resolveProvider: some(false))),
      documentSymbolProvider: some(true),
      codeActionProvider: some(true),
      documentFormattingProvider: some(getNphPath().isSome),
    )
  )
  # Support rename by default, but check if we can also support prepare
  result.capabilities.renameProvider = %true
  if params.capabilities.textDocument.isSome:
    let docCaps = params.capabilities.textDocument.unsafeGet()
    # Check if the client support prepareRename
    #TODO do the test on the action
    if docCaps.rename.isSome and docCaps.rename.get().prepareSupport.get(false):
      result.capabilities.renameProvider = %*{"prepareProvider": true}
  debug "Initialize completed. Trying to start nimsuggest instances"

  let ls = p.ls
  ls.serverCapabilities = result.capabilities
  let rootPath = ls.initializeParams.getRootPath
  if rootPath != "":
    let nimbleFiles = walkFiles(rootPath / "*.nimble").toSeq
    if nimbleFiles.len > 0:
      let nimbleFile = nimbleFiles[0]
      let nimbleDumpInfo = await ls.getNimbleDumpInfo(nimbleFile)
      ls.entryPoints =
        nimbleDumpInfo.getNimbleEntryPoints(ls.initializeParams.getRootPath)
      # ls.showMessage(fmt "Found entry point {ls.entryPoints}?", MessageType.Info)
      for entryPoint in ls.entryPoints:
        debug "Starting nimsuggest for entry point ", entry = entryPoint
        if entryPoint notin ls.projectFiles:
          ls.createOrRestartNimsuggest(entryPoint)

proc toCompletionItem(suggest: Suggest): CompletionItem =
  with suggest:
    return
      CompletionItem %* {
        "label": qualifiedPath[^1].strip(chars = {'`'}),
        "kind": nimSymToLSPKind(suggest).int,
        "documentation": doc,
        "detail": nimSymDetails(suggest),
      }

proc completion*(
    ls: LanguageServer, params: CompletionParams, id: int
): Future[seq[CompletionItem]] {.async.} =
  with (params.position, params.textDocument):
    asyncSpawn ls.addProjectFileToPendingRequest(id.uint, uri)
    let nimsuggest = await ls.tryGetNimsuggest(uri)
    if nimsuggest.isNone():
      return @[]
    let ch = ls.getCharacter(uri, line, character)
    if ch.isNone:
      return @[]
    let completions =
      await nimsuggest.get.sug(uriToPath(uri), ls.uriToStash(uri), line + 1, ch.get)
    result = completions.map(toCompletionItem)

    if ls.clientCapabilities.supportSignatureHelp() and
        nsCon in nimSuggest.get.capabilities:
      #show only unique overloads if we support signatureHelp
      var unique = initTable[string, CompletionItem]()
      for completion in result:
        if completion.label notin unique:
          unique[completion.label] = completion
      result = unique.values.toSeq

proc toLocation*(suggest: Suggest): Location =
  return
    Location %* {"uri": pathToUri(suggest.filepath), "range": toLabelRange(suggest)}

proc definition*(
    ls: LanguageServer, params: TextDocumentPositionParams, id: int
): Future[seq[Location]] {.async.} =
  with (params.position, params.textDocument):
    asyncSpawn ls.addProjectFileToPendingRequest(id.uint, uri)
    let ns = await ls.tryGetNimsuggest(uri)
    if ns.isNone:
      return @[]
    let ch = ls.getCharacter(uri, line, character)
    if ch.isNone:
      return @[]
    result = ns.get
      .def(uriToPath(uri), ls.uriToStash(uri), line + 1, ch.get)
      .await()
      .map(x => x.toUtf16Pos(ls).toLocation)

proc declaration*(
    ls: LanguageServer, params: TextDocumentPositionParams, id: int
): Future[seq[Location]] {.async.} =
  with (params.position, params.textDocument):
    asyncSpawn ls.addProjectFileToPendingRequest(id.uint, uri)
    let ns = await ls.tryGetNimsuggest(uri)
    if ns.isNone:
      return @[]
    let ch = ls.getCharacter(uri, line, character)
    if ch.isNone:
      return @[]
    result = ns.get
      .declaration(uriToPath(uri), ls.uriToStash(uri), line + 1, ch.get)
      .await()
      .map(x => x.toUtf16Pos(ls).toLocation)

proc expandAll*(
    ls: LanguageServer, params: TextDocumentPositionParams
): Future[ExpandResult] {.async.} =
  with (params.position, params.textDocument):
    let ns = await ls.tryGetNimsuggest(uri)
    if ns.isNone:
      return ExpandResult() #TODO make it optional
    let ch = ls.getCharacter(uri, line, character)
    if ch.isNone:
      return ExpandResult()
    let expand =
      ns.get.expand(uriToPath(uri), ls.uriToStash(uri), line + 1, ch.get).await()

proc createRangeFromSuggest(suggest: Suggest): Range =
  result = range(suggest.line - 1, 0, suggest.endLine - 1, suggest.endCol)

proc fixIdentation(s: string, indent: int): string =
  result = s
    .split("\n")
    .mapIt(
      if (it != ""):
        repeat(" ", indent) & it
      else:
        it
    )
    .join("\n")

proc expand*(
    ls: LanguageServer, params: ExpandTextDocumentPositionParams
): Future[ExpandResult] {.async.} =
  with (params, params.position, params.textDocument):
    let
      lvl = level.get(-1)
      tag =
        if lvl == -1:
          "all"
        else:
          $lvl
      ns = await ls.tryGetNimsuggest(uri)
    if ns.isNone:
      return ExpandResult()
    let ch = ls.getCharacter(uri, line, character)
    if ch.isNone:
      return ExpandResult()
    let expand = ns.get
      .expand(uriToPath(uri), ls.uriToStash(uri), line + 1, ch.get, fmt "  {tag}")
      .await()
    if expand.len != 0:
      result = ExpandResult(
        content: expand[0].doc.fixIdentation(character),
        range: expand[0].createRangeFromSuggest(),
      )

proc status*(
    ls: LanguageServer, params: NimLangServerStatusParams
): Future[NimLangServerStatus] {.async.} =
  debug "Received status request"
  ls.getLspStatus()

proc extensionCapabilities*(
    ls: LanguageServer, _: JsonNode
): Future[seq[string]] {.async.} =
  ls.extensionCapabilities.toSeq.mapIt($it)

proc extensionSuggest*(
    ls: LanguageServer, params: SuggestParams
): Future[SuggestResult] {.async.} =
  debug "[Extension Suggest]", params = params
  var projectFile = params.projectFile
  if projectFile != "" and projectFile notin ls.projectFiles:
    #test if just a regular file
    let uri = projectFile.pathToUri
    if uri in ls.openFiles:
      let openFile = ls.openFiles[uri]
      projectFile = await openFile.projectFile
      debug "[ExtensionSuggest] Found project file for ",
        file = params.projectFile, project = projectFile
    else:
      error "Project file must exists ", params = params
      return SuggestResult()
  template restart(ls: LanguageServer, project: Project) =
    ls.showMessage(fmt "Restarting nimsuggest {projectFile}", MessageType.Info)
    project.errorCallback = none(ProjectCallback)
    project.stop()
    ls.createOrRestartNimsuggest(projectFile, projectFile.pathToUri)
    ls.sendStatusChanged()

  case params.action
  of saRestart:
    let project = ls.projectFiles[projectFile]
    ls.restart(project)
    SuggestResult(actionPerformed: saRestart)
  of saRestartAll:
    let projectFiles = ls.projectFiles.keys.toSeq()
    for projectFile in projectFiles:
      let project = ls.projectFiles[projectFile]
      ls.restart(project)
    SuggestResult(actionPerformed: saRestartAll)
  of saNone:
    error "An action must be specified", params = params
    SuggestResult()

proc typeDefinition*(
    ls: LanguageServer, params: TextDocumentPositionParams, id: int
): Future[seq[Location]] {.async.} =
  with (params.position, params.textDocument):
    asyncSpawn ls.addProjectFileToPendingRequest(id.uint, uri)
    let ns = await ls.tryGetNimSuggest(uri)
    if ns.isNone:
      return @[]
    let ch = ls.getCharacter(uri, line, character)
    if ch.isNone:
      return @[]
    result = ns.get
      .`type`(uriToPath(uri), ls.uriToStash(uri), line + 1, ch.get)
      .await()
      .map(x => x.toUtf16Pos(ls).toLocation)

proc toSymbolInformation*(suggest: Suggest): SymbolInformation =
  with suggest:
    return
      SymbolInformation %* {
        "location": toLocation(suggest),
        "kind": nimSymToLSPSymbolKind(suggest.symKind).int,
        "name": suggest.name,
      }

proc documentSymbols*(
    ls: LanguageServer, params: DocumentSymbolParams, id: int
): Future[seq[SymbolInformation]] {.async.} =
  let uri = params.textDocument.uri
  asyncSpawn ls.addProjectFileToPendingRequest(id.uint, uri)
  let ns = await ls.tryGetNimsuggest(uri)
  if ns.isSome:
    ns.get().outline(uriToPath(uri), ls.uriToStash(uri)).await().map(
      x => x.toUtf16Pos(ls).toSymbolInformation
    )
  else:
    @[]

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

  sleepAsync(FILE_CHECK_DELAY).addCallback do():
    if not cancelFuture.finished:
      fileData.checkInProgress = true
      ls.checkFile(uri).addCallback do() {.gcsafe, raises: [].}:
        try:
          ls.openFiles[uri].checkInProgress = false
          if fileData.needsChecking:
            fileData.needsChecking = false
            ls.scheduleFileCheck(uri)
        except KeyError:
          discard
        # except Exception:
        #   discard

proc toMdLinks(s: string): string =
  result = s
  let matches = s.findAll(re2"`([^`<]*?)<([^`>]*?)>`_")
  for i in countDown(matches.high, matches.low):
    let match = matches[i]
    result[match.boundaries] = fmt"[{s[match.captures[0]]}]({s[match.captures[1]]})"
  
proc toMarkupContent(suggest: Suggest): MarkupContent =
  result = MarkupContent(kind: "markdown", value: "```nim\n")
  result.value.add suggest.qualifiedPath.join(".")
  if suggest.forth.len != 0:
    result.value.add ": "
    result.value.add suggest.forth
  result.value.add "\n```"

  if suggest.doc.len != 0:
    result.value.add "\n\n---\n"
    result.value.add toMdLinks(suggest.doc)

proc hover*(
    ls: LanguageServer, params: HoverParams, id: int
): Future[Option[Hover]] {.async.} =
  with (params.position, params.textDocument):
    let config = await ls.getWorkspaceConfiguration()
    asyncSpawn ls.addProjectFileToPendingRequest(id.uint, uri)
    let nimsuggest = await ls.tryGetNimsuggest(uri)
    if nimsuggest.isNone:
      return none(Hover)
    let ch = ls.getCharacter(uri, line, character)
    if ch.isNone:
      return none(Hover)
    let suggestions =
      await nimsuggest.get().highlight(uriToPath(uri), ls.uriToStash(uri), line + 1, ch.get)
    if suggestions.len == 0:
      return none(Hover)
    var suggest = suggestions[0]
    if suggest.symkind == "skModule": # NOTE: skMoudle always return position (1, 0)
      return some(Hover(contents: some(%toMarkupContent(suggest))))
    else:
      for s in suggestions:
        if s.line == line + 1:
          if s.column <= ch.get:
            suggest = s
          else:
            break
      var content = toMarkupContent(suggest)
      if suggest.symkind == "skMacro" and config.nimExpandMacro.get(NIM_EXPAND_MACRO_BY_DEFAULT):
        let expanded = await nimsuggest.get
          .expand(uriToPath(uri), ls.uriToStash(uri), suggest.line, suggest.column)
        if expanded.len > 0 and expanded[0].doc != "":
          # debug "Expanded macro", expanded = expanded[0].doc
          content.value.add &"```nim\n{expanded[0].doc}\n```"
        else:          
          # debug "Couldnt expand the macro. Trying with nim expand", suggest = suggest[]
          let nimPath = config.getNimPath()
          if nimPath.isSome:  
            let expanded = await nimExpandMacro(nimPath.get, suggest, uriToPath(uri))
            content.value.add &"```nim\n{expanded}\n```"
      if suggest.section == ideDef and suggest.symkind in ["skProc"] and config.nimExpandArc.get(NIM_EXPAND_ARC_BY_DEFAULT):
        debug "#Expanding arc", suggest = suggest[]
        let nimPath = config.getNimPath()
        if nimPath.isSome:  
          let expanded = await nimExpandArc(nimPath.get, suggest, uriToPath(uri))
          let arcContent = "#Expanded arc \n" & expanded
          content.value.add &"```nim\n{arcContent}\n```"
      return some(Hover(
        contents: some(%content),
        range: some(toLabelRange(suggest.toUtf16Pos(ls))),
      ))

proc references*(
    ls: LanguageServer, params: ReferenceParams
): Future[seq[Location]] {.async.} =
  with (params.position, params.textDocument, params.context):
    let nimsuggest = await ls.tryGetNimsuggest(uri)
    if nimsuggest.isNone:
      return @[]
    let ch = ls.getCharacter(uri, line, character)
    if ch.isNone:
      return @[]
    let refs =
      await nimsuggest.get.use(uriToPath(uri), ls.uriToStash(uri), line + 1, ch.get)
    result = refs.filter(suggest => suggest.section != ideDef or includeDeclaration).map(
        x => x.toUtf16Pos(ls).toLocation
      )

proc prepareRename*(
    ls: LanguageServer, params: PrepareRenameParams, id: int
): Future[JsonNode] {.async.} =
  with (params.position, params.textDocument):
    asyncSpawn ls.addProjectFileToPendingRequest(id.uint, uri)
    let nimsuggest = await ls.tryGetNimsuggest(uri)
    if nimsuggest.isNone:
      return newJNull()
    let ch = ls.getCharacter(uri, line, character)
    if ch.isNone:
      return newJNull()
    let def =
      await nimsuggest.get.def(uriToPath(uri), ls.uriToStash(uri), line + 1, ch.get)
    if def.len == 0:
      return newJNull()
    # Check if the symbol belongs to the project
    let projectDir = ls.initializeParams.getRootPath
    if def[0].filePath.isRelTo(projectDir):
      return %def[0].toLocation().range

    return newJNull()

proc rename*(
    ls: LanguageServer, params: RenameParams, id: int
): Future[WorkspaceEdit] {.async.} =
  # We reuse the references command as to not duplicate it  
  let references = await ls.references(
    ReferenceParams(
      context: ReferenceContext(includeDeclaration: true),
      textDocument: params.textDocument,
      position: params.position,
    )
  )
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

proc toInlayHint(suggest: SuggestInlayHint, configuration: NlsConfig): InlayHint =
  let hint_line = suggest.line - 1
  # TODO: how to convert column?
  var hint_col = suggest.column
  var suggest = suggest
  if suggest.label.contains("Error Type"):
    suggest.label = ""
  result = InlayHint(
    position: Position(line: hint_line, character: hint_col),
    label: suggest.label,
    kind: some(convertInlayHintKind(suggest.kind)),
    paddingLeft: some(suggest.paddingLeft),
    paddingRight: some(suggest.paddingRight),
  )
  if suggest.kind == sihkException and suggest.label == "try " and
      configuration.inlayHints.isSome and
      configuration.inlayHints.get.exceptionHints.isSome and
      configuration.inlayHints.get.exceptionHints.get.hintStringLeft.isSome:
    result.label = configuration.inlayHints.get.exceptionHints.get.hintStringLeft.get
  if suggest.kind == sihkException and suggest.label == "!" and
      configuration.inlayHints.isSome and
      configuration.inlayHints.get.exceptionHints.isSome and
      configuration.inlayHints.get.exceptionHints.get.hintStringRight.isSome:
    result.label = configuration.inlayHints.get.exceptionHints.get.hintStringRight.get
  if suggest.tooltip != "":
    result.tooltip = some(suggest.tooltip)
  else:
    result.tooltip = some("")
  if suggest.allowInsert:
    result.textEdits = some(
      @[
        TextEdit(
          newText: suggest.label,
          `range`: Range(
            start: Position(line: hint_line, character: hint_col),
            `end`: Position(line: hint_line, character: hint_col),
          ),
        )
      ]
    )

proc inlayHint*(
    ls: LanguageServer, params: InlayHintParams, id: int
): Future[seq[InlayHint]] {.async.} =
  debug "inlayHint received..."
  with (params.range, params.textDocument):
    asyncSpawn ls.addProjectFileToPendingRequest(id.uint, uri)
    let
      configuration = ls.getWorkspaceConfiguration.await()
      nimsuggest = await ls.tryGetNimsuggest(uri)

    if nimsuggest.isNone or nimsuggest.get.protocolVersion < 4 or
        not configuration.inlayHintsEnabled:
      return @[]
    let ch = ls.getCharacter(uri, start.line, start.character)
    if ch.isNone:
      return @[]
    let suggestions = await nimsuggest.get.inlayHints(
      uriToPath(uri),
      ls.uriToStash(uri),
      start.line + 1,
      ch.get,
      `end`.line + 1,
      ch.get,
      " +exceptionHints +parameterHints",
    )
    result = suggestions
      .filter(
        x =>
          ((x.inlayHintInfo.kind == sihkType) and configuration.typeHintsEnabled) or (
            (x.inlayHintInfo.kind == sihkException) and
            configuration.exceptionHintsEnabled
          ) or (
            (x.inlayHintInfo.kind == sihkParameter) and
            configuration.parameterHintsEnabled
          )
      )
      .map(x => x.inlayHintInfo.toUtf16Pos(ls, uri).toInlayHint(configuration))
      .filter(x => x.label != "")

proc codeAction*(
    ls: LanguageServer, params: CodeActionParams
): Future[seq[CodeAction]] {.async.} =
  let projectUri = await getProjectFile(params.textDocument.uri.uriToPath, ls)
  return
    seq[CodeAction] %* [
      {
        "title": "Clean build",
        "kind": "source",
        "command": {
          "title": "Clean build",
          "command": RECOMPILE_COMMAND,
          "arguments": @[projectUri],
        },
      },
      {
        "title": "Refresh project errors",
        "kind": "source",
        "command": {
          "title": "Refresh project errors",
          "command": CHECK_PROJECT_COMMAND,
          "arguments": @[projectUri],
        },
      },
      {
        "title": "Restart nimsuggest",
        "kind": "source",
        "command": {
          "title": "Restart nimsuggest",
          "command": RESTART_COMMAND,
          "arguments": @[projectUri],
        },
      },
    ]

proc executeCommand*(
    ls: LanguageServer, params: ExecuteCommandParams
): Future[JsonNode] {.async.} =
  let projectFile = params.arguments[0].getStr
  case params.command
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
      ns = ls.projectFiles.getOrDefault(projectFile).ns
    if ns != nil:
      ls.workDoneProgressCreate(token)
      ls.progress(token, "begin", fmt "Compiling project {projectFile}")

      ns.await().recompile().addCallback do():
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
  return
    SignatureInformation %* {
      "label": label,
      "documentation": suggest.doc,
      "parameters": newSeq[ParameterInformation](), #notice params is not used
    }

proc signatureHelp*(
    ls: LanguageServer, params: SignatureHelpParams, id: int
): Future[Option[SignatureHelp]] {.async.} =
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
    asyncSpawn ls.addProjectFileToPendingRequest(id.uint, uri)
    let nimsuggest = await ls.tryGetNimsuggest(uri)
    if nimsuggest.isNone:
      return none[SignatureHelp]()
    if nsCon notin nimSuggest.get.capabilities:
      #support signatureHelp only if the current version of NimSuggest supports it.
      return none[SignatureHelp]()
    let ch = ls.getCharacter(uri, line, character)
    if ch.isNone:
      return none[SignatureHelp]()
    let completions =
      await nimsuggest.get.con(uriToPath(uri), ls.uriToStash(uri), line + 1, ch.get)
    let signatures = completions.map(toSignatureInformation)
    if signatures.len() > 0:
      return some SignatureHelp(
        signatures: some(signatures), activeSignature: some(0), activeParameter: some(0)
      )
    else:
      return none[SignatureHelp]()

proc format*(
    ls: LanguageServer, nphPath, uri: string
): Future[Option[TextEdit]] {.async.} =
  let filePath = ls.uriStorageLocation(uri)
  if not fileExists(filePath):
    warn "File doenst exist ", filePath = filePath, uri = uri
    return none(TextEdit)

  debug "nph starts", nphPath = nphPath, filePath = filePath
  let process = await startProcess(
    nphPath,
    arguments = @[filePath],
    options = {UsePath},
    stderrHandle = AsyncProcess.Pipe,
  )
  let res = await process.waitForExit(InfiniteDuration)
  if res != 0:
    let err = string.fromBytes(process.stderrStream.read().await)
    error "There was an error trying to format the document. ", err = err
    ls.showMessage(&"Error formating {uri}:{err}", MessageType.Error)
    return none(TextEdit)

  #if enough time has passed since last modification, we skip the formatting:   
  let lastModified = getLastModificationTime(filePath)
  let timeSinceLastModified = getTime() - lastModified
  let cond = timeSinceLastModified >= initDuration(seconds = 2)

  if timeSinceLastModified >= initDuration(seconds = 2):
    error "Skipping formatting because the file was modifyed long ago"
    return none(TextEdit)

  let formattedText = readFile(filePath)
  if formattedText.len < 2:
    error "Failed to format document", uri = uri
    return none(TextEdit)

  let fullRange = Range(
    start: Position(line: 0, character: 0),
    `end`: Position(line: uinteger.high, character: uinteger.high)
  )
  debug "Formatting document", uri = uri, formattedText = formattedText
  some TextEdit(range: fullRange, newText: formattedText)

proc formatting*(
    ls: LanguageServer, params: DocumentFormattingParams, id: int
): Future[seq[TextEdit]] {.async.} =
  with (params.textDocument):
    asyncSpawn ls.addProjectFileToPendingRequest(id.uint, uri)
    debug "Received Formatting request "
    let formatTextEdit = await ls.format(getNphPath().get(), uri)
    if formatTextEdit.isSome:
      return @[formatTextEdit.get]

proc workspaceSymbol*(
    ls: LanguageServer, params: WorkspaceSymbolParams, id: int
): Future[seq[SymbolInformation]] {.async.} =
  if ls.lastNimsuggest != nil:
    let
      nimsuggest = await ls.lastNimsuggest
      symbols = await nimsuggest.globalSymbols(params.query, "-")
    return symbols.map(x => x.toUtf16Pos(ls).toSymbolInformation)

proc toDocumentHighlight(suggest: Suggest): DocumentHighlight =
  return DocumentHighlight %* {"range": toLabelRange(suggest)}

proc documentHighlight*(
    ls: LanguageServer, params: TextDocumentPositionParams, id: int
): Future[seq[DocumentHighlight]] {.async.} =
  with (params.position, params.textDocument):
    asyncSpawn ls.addProjectFileToPendingRequest(id.uint, uri)
    let nimsuggest = await ls.tryGetNimsuggest(uri)
    if nimsuggest.isNone:
      return @[]
    let ch = ls.getCharacter(uri, line, character)
    if ch.isNone:
      return @[]
    let suggestLocations = await nimsuggest.get.highlight(
      uriToPath(uri), ls.uriToStash(uri), line + 1, ch.get
    )
    result = suggestLocations.map(x => x.toUtf16Pos(ls).toDocumentHighlight)

proc extractId(id: JsonNode): int =
  if id.kind == JInt:
    result = id.getInt
  if id.kind == JString:
    discard parseInt(id.getStr, result)

proc shutdown*(
    ls: LanguageServer, input: JsonNode
): Future[JsonNode] {.async, gcsafe.} =
  debug "Shutting down"
  await ls.stopNimsuggestProcesses()
  ls.isShutdown = true
  # let id = input{"id"}.extractId
  result = newJNull()
  trace "Shutdown complete"

proc exit*(
    p: tuple[ls: LanguageServer, onExit: OnExitCallback], _: JsonNode
): Future[JsonNode] {.async, gcsafe.} =
  if not p.ls.isShutdown:
    debug "Received an exit request without prior shutdown request"
    await p.ls.stopNimsuggestProcesses()
  debug "Quitting process"
  result = newJNull()
  await p.onExit()

proc startNimbleProcess(ls: LanguageServer, args: seq[string]): Future[AsyncProcessRef] {.async.} =
  await startProcess(
    "nimble",
    arguments = args,
    options = {UsePath},
    workingDir = ls.initializeParams.getRootPath,
    stdoutHandle = AsyncProcess.Pipe,
    stderrHandle = AsyncProcess.Pipe,
  )

proc tasks*(
    ls: LanguageServer, conf: JsonNode
): Future[seq[NimbleTask]] {.async.} =
  let rootPath: string = ls.initializeParams.getRootPath
  debug "Received tasks ", rootPath = rootPath
  delEnv "NIMBLE_DIR"
  let process = await ls.startNimbleProcess(@["tasks"])
  let res =
    await process.waitForExit(InfiniteDuration) #TODO handle error (i.e. no nimble file)
  let output = await process.stdoutStream.readLine()
  var name, desc: string
  for line in output.splitLines:
    if scanf(line, "$+  $*", name, desc):
      #first run of nimble tasks can compile nim and output the result of the compilation
      if name.isWord:
        result.add NimbleTask(name: name.strip(), description: desc.strip())
  await process.shutdownChildProcess()

proc runTask*(
    ls: LanguageServer, params: RunTaskParams
): Future[RunTaskResult] {.async.} =
  let process = await ls.startNimbleProcess(params.command) 
  let res = await process.waitForExit(InfiniteDuration)
  result.command = params.command
  let prefix = "\""
  while not process.stdoutStream.atEof():
    var lines = process.stdoutStream.readLine().await.splitLines
    for line in lines.mitems:
      if line.startsWith(prefix):
        line = line.unescape(prefix)
      if line != "":  
        result.output.add line  
        
  debug "Ran nimble cmd/task", command = $params.command, output = $result.output
  await process.shutdownChildProcess()

proc listTests*(
    ls: LanguageServer, params: ListTestsParams
): Future[ListTestsResult] {.async.} =
  let config = await ls.getWorkspaceConfiguration()
  let nimPath = config.getNimPath()
  if nimPath.isNone:
    error "Nim path not found when listing tests"
    return ListTestsResult(projectInfo: TestProjectInfo(entryPoint: params.entryPoint, suites: initTable[string, TestSuiteInfo]()))
  let workspaceRoot = ls.initializeParams.getRootPath
  let testProjectInfo = await listTests(params.entryPoint, nimPath.get(), workspaceRoot)
  result.projectInfo = testProjectInfo

proc runTests*(
    ls: LanguageServer, params: RunTestParams
): Future[RunTestProjectResult] {.async.} =
  let config = await ls.getWorkspaceConfiguration()
  let nimPath = config.getNimPath()
  if nimPath.isNone:
    error "Nim path not found when running tests"
    return RunTestProjectResult()
  let workspaceRoot = ls.initializeParams.getRootPath
  await runTests(params.entryPoint, nimPath.get(), params.suiteName, params.testNames.get(@[]), workspaceRoot, ls)

proc cancelTest*(
    ls: LanguageServer, params: JsonNode
): Future[CancelTestResult] {.async.} =
  debug "Cancelling test"
  if ls.testRunProcess.isSome: #No need to cancel the runTests request. The client should handle it.
    await shutdownChildProcess(ls.testRunProcess.get)
    ls.testRunProcess = none(AsyncProcessRef)
    CancelTestResult(cancelled: true)
  else:
    CancelTestResult(cancelled: false)

#Notifications
proc initialized*(ls: LanguageServer, _: JsonNode): Future[void] {.async.} =
  debug "Client initialized."
  maybeRegisterCapabilityDidChangeConfiguration(ls)
  maybeRequestConfigurationFromClient(ls)

proc cancelRequest*(ls: LanguageServer, params: CancelParams): Future[void] {.async.} =
  if params.id.isSome:
    let id = params.id.get.getInt.uint
    if id notin ls.pendingRequests:
      return
    let pendingRequest = ls.pendingRequests[id]
    if ls.pendingRequests[id].request != nil:
      debug "Cancelling: ", id = id
      await ls.pendingRequests[id].request.cancelAndWait()
      ls.pendingRequests[id].state = prsCancelled
      ls.pendingRequests[id].endTime = now()

proc setTrace*(ls: LanguageServer, params: SetTraceParams) {.async.} =
  debug "setTrace", value = params.value

proc didChange*(
    ls: LanguageServer, params: DidChangeTextDocumentParams
): Future[void] {.async, gcsafe.} =
  with params:
    let uri = textDocument.uri
    if uri notin ls.openFiles:
      return
    let file = open(ls.uriStorageLocation(uri), fmWrite)

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

proc willSaveWaitUntil*(
    ls: LanguageServer, 
    params: WillSaveTextDocumentParams
): Future[seq[TextEdit]] {.async.} =
  debug "Received willSaveWaitUntil request"

  let
    uri = params.textDocument.uri
    config = await ls.getWorkspaceConfiguration()
    nphPath = getNphPath()
  
  let shouldFormat = 
    nphPath.isSome and 
    ls.serverCapabilities.documentFormattingProvider.get(false) and
    config.formatOnSave.get(false)
    
  if shouldFormat:
    debug "Formatting document before save", uri = uri
    let formatTextEdit = await ls.format(nphPath.get(), uri)
    if formatTextEdit.isSome:
      return @[formatTextEdit.get]
  
  return @[]

proc didSave*(
    ls: LanguageServer, params: DidSaveTextDocumentParams
): Future[void] {.async, gcsafe.} =
  let
    uri = params.textDocument.uri
    config = await ls.getWorkspaceConfiguration()
  let nimsuggest = await ls.tryGetNimsuggest(uri)

  if nimsuggest.isNone:
    return

  ls.openFiles[uri].changed = false
  traceAsyncErrors nimsuggest.get.changed(uriToPath(uri))

  if config.checkOnSave.get(true):
    debug "Checking project", uri = uri
    traceAsyncErrors ls.checkProject(uri)

  # var toStop = newTable[string, Nimsuggest]()
  # #We first get the project file for the current file so we can test if this file recently imported another project
  # let thisProjectFile = await getProjectFile(uri.uriToPath, ls)

  # let ns: NimSuggest = await ls.projectFiles[thisProjectFile]
  # if ns.canHandleUnknown:
  #   for projectFile in ls.projectFiles.keys:
  #     if projectFile in ls.entryPoints: continue
  #     let isKnown = await ns.isKnown(projectFile)
  #     if isKnown:
  #       toStop[projectFile] = await ls.projectFiles[projectFile]

  #   for projectFile, ns in toStop:
  #     ns.stop()
  #     ls.projectFiles.del projectFile
  #   if toStop.len > 0:
  #     ls.sendStatusChanged()

proc didClose*(
    ls: LanguageServer, params: DidCloseTextDocumentParams
): Future[void] {.async, gcsafe.} =
  await ls.didCloseFile(params.textDocument.uri)

proc didOpen*(
    ls: LanguageServer, params: DidOpenTextDocumentParams
): Future[void] {.async, gcsafe.} =
  await ls.didOpenFile(params.textDocument)

proc didChangeConfiguration*(
    ls: LanguageServer, conf: JsonNode
): Future[void] {.async, gcsafe.} =
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
