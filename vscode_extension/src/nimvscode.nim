## This is the extension file that gets loaded by vscode

when not defined(js):
  {.error: "This module only works on the JavaScript platform".}

import platform/vscodeApi
import platform/js/[jsre, jsString, jsNodeFs, jsNodePath, jsNodeCp]
import tools/nimBinTools
import std/[strformat, jsconsole, strutils, options, sugar, json]
from std/os import `/`
import spec
import
  nimRename, nimSuggest, nimDeclaration, nimReferences, nimOutline, nimSignature,
  nimHover, nimFormatting, nimLspStatusPanel, nimStatus

from nimBuild import check, execSelectionInTerminal, activateEvalConsole, CheckResult
from nimStatus import showHideStatus
from nimIndexer import initWorkspace, clearCaches, onClose
from nimImports import initImports, removeFileFromImports, addFileToImports
from nimSuggestExec import
  extensionContext, initNimSuggest, closeAllNimSuggestProcesses, restartNimsuggest
from nimUtils import ext, getDirtyFile, outputLine
from nimProjects import processConfig, configUpdate
from nimMode import mode
import nimLsp, nimcodelenses
import nimtest

var state: ExtensionState
var diagnosticCollection {.threadvar.}: VscodeDiagnosticCollection
var fileWatcher {.threadvar.}: VscodeFileSystemWatcher
var terminal {.threadvar.}: VscodeTerminal

type
  # FileExtensions* {.pure, size: sizeof(cint).} = enum
  #     nimble, nims, nimCfg = "nim.cfg", cfg, nim
  CandidateKind* {.pure, size: sizeof(cint).} = enum
    nimble
    prjNims
    configNims
    prjNimCfg
    cfg
    nim

  CandidateKinds* = set[CandidateKind]
  CandidateMatchBoost* {.pure.} = enum
    noBoost
    nameMatchesParentViaSrc
    nameMatchesParent

  CandidateProject* = ref object
    workspaceFolder*: VscodeWorkspaceFolder
    kinds*: CandidateKinds
    matchBoost*: CandidateMatchBoost
    name*: cstring
    fsPath*: cstring
    coverPathPrefixes*: seq[cstring]

  UserProvidedProject* = ref object
    name*: cstring

let defaultIndexExcludeGlobs = block:
  let res = newJsAssoc[cstring, bool]()
  res[cstring "**" / ".git" / "**"] = true
  res[cstring "nimcache" / "**"] = true
  res ## exclude these by default as most people will not want them indexed

proc listCandidateProjects() =
  ## Find all the "projects" in the workspace and folders
  ##
  ## Rules for project discovery, is a folder oriented decision tree. The top
  ## level decision tree starts off as follows:
  ## 1. ignore symlinks
  ## #. ignore folders prefixed with '.' (.git, .vscode, etc...)
  ## #. ignore folders unlikely to be useful (node_modules)
  ## #. ignore non-nim files
  ## #. discover projects (see below)
  ##
  ## Discover projects, order indicates preference:
  ## 1. `foo.nimble` in `/foo` dir
  ##    (proj=foo, cover=nimble `srcDir` and `binDir`, `/foo/tests`)
  ## #. `bar.nimble` in `/foo` dir
  ##    (proj=bar, cover=nimble `srcDir` and `binDir`, `/foo/bar`)
  ## #. `foo.nim` and `foo.(nims|nim.cfg)` in `/foo` and no `/foo/src`
  ##    (proj=foo, cover=`/foo`)
  ## #. `foo.nim` and `foo.(nims|nim.cfg)` in `/foo` and `/foo/src`
  ##    (proj=foo, cover=`/foo/(src|tests)`)
  ## #. `foo.nims` in `/foo` and no `/foo/src`
  ##    (proj=foo, cover=`/foo`, non-project *.nim)
  ## #. `foo.nims` in `/foo` and `/foo/src`
  ##    (proj=foo, cover=`/foo/(foo|tests|src)`)
  ## #. `bar.nims` in `/foo` and `/foo/bar`
  ##    (proj=bar, cover=`/foo/bar`)
  ## #. `foo.nim` and `foo.(nims|nim.cfg)` in `/bar`
  ##    (proj=foo, cover=`/bar/foo`)
  ## #. `/foo/src/foo.(nim|nims|nim.cfg)`
  ##    (proj=foo, cover=`/foo/(src|test)`)
  ## #. `/bar/src/foo.(nim|nims|nim.cfg)`
  ##    (proj=foo, cover=`/foo/(src|test)`)
  ## #. `foo.nim` and no (`*.(nims|nim.cfg|)` or `nim.cfg`) in `/foo`
  ##    (proj=foo, cover=`/foo`)
  ## #. if none of the above, resort to one .nim one project
  ##
  ## TODO - finish implementing
  var map = newMap[cstring, Array[CandidateProject]]()
  for folder in vscode.workspace.workspaceFolders:
    map[folder.name] = newArray[CandidateProject]()

    vscode.workspace.fs
    .readDirectory(folder.uri)
    .then(
      proc(r: Array[VscodeReadDirResult]) =
        for i in r:
          case i.fileType
          of symbolicLink, symlinkDir, unknown:
            continue #skip symlinks & unknowns
          else:
            var kind =
              if i.name.endsWith(".nimble"):
                nimble
              elif i.name.endsWith(".nim.cfg"):
                prjNimCfg
              elif i.name.endsWith("nim.cfg"):
                cfg
              elif i.name.endsWith("config.nims"):
                configNims
              elif i.name.endsWith(".nims"):
                prjNims
              elif i.name.endsWith(".nim"):
                nim
              else:
                continue

            map[folder.name].add(
              CandidateProject(
                workspaceFolder: folder,
                kinds: {kind},
                name: i.name,
                fsPath: path.join(folder.uri.fsPath, i.name),
              )
            )

            # TODO check dir entries if nothing found
        for n, cs in map.entries():
          for c in cs:
            outputLine(
              fmt"[info] workspaceFolder: {n}, name: {c.name}, kind: {$(c.kinds)}".cstring
            )
    ).catch do(r: JsObject):
      console.error(r)

proc mapSeverityToVscodeSeverity(sev: cstring): VscodeDiagnosticSeverity =
  return
    case $(sev)
    of "Hint": VscodeDiagnosticSeverity.information
    of "Warning": VscodeDiagnosticSeverity.warning
    of "Error": VscodeDiagnosticSeverity.error
    else: VscodeDiagnosticSeverity.error

proc findErrorRange(msg: cstring, line, column: cint): VscodeRange =
  var endColumn = column
  if msg.contains("'"):
    # -1 because findLast includes the index of the quote
    endColumn += msg.findLast("'") - msg.find("'") - 1

  let line = max(0, line - 1)

  vscode.newRange(line, max(0, column - 1), line, max(0, endColumn - 1))

proc runCheck(doc: VscodeTextDocument = nil): void =
  var config = vscode.workspace.getConfiguration("nim")
  var document = doc
  if document.isNil() and not vscode.window.activeTextEditor.isNil():
    document = vscode.window.activeTextEditor.document

  if document.isNil() or document.languageId != "nim" or
      document.fileName.endsWith("nim.cfg"):
    return

  var uri = document.uri

  vscode.window
  .withProgress(
    VscodeProgressOptions{
      location: VscodeProgressLocation.window,
      cancellable: false,
      title: "Nim: check project...",
    },
    proc(): Promise[seq[CheckResult]] =
      check(uri.fsPath, config),
  )
  .then(
    proc(errors: seq[CheckResult]) =
      diagnosticCollection.clear()

      var diagnosticMap = newMap[cstring, Array[VscodeDiagnostic]]()
      var err = newMap[cstring, bool]()
      for error in errors:
        var errorId =
          error.file & cstring($error.line) & cstring($error.column) & error.msg
        if not err[errorId]:
          var targetUri = error.file

          var diagnostic = vscode.newDiagnostic(
            findErrorRange(error.msg, error.line, error.column),
            error.msg,
            mapSeverityToVscodeSeverity(error.severity),
          )
          if error.stacktrace.len > 0:
            diagnostic.relatedInformation =
              newArray[VscodeDiagnosticRelatedInformation]()
            for entry in error.stacktrace:
              diagnostic.relatedInformation.add(
                vscode.newDiagnosticRelatedInformation(
                  vscode.newLocation(
                    vscode.uriFile(entry.file),
                    findErrorRange(entry.msg, entry.line, entry.column),
                  ),
                  entry.msg,
                )
              )
          if not diagnosticMap.has(targetUri):
            diagnosticMap[targetUri] = newArray[VscodeDiagnostic]()
          diagnosticMap[targetUri].push(diagnostic)
          err[errorId] = true

      var entries: seq[array[0 .. 1, JsObject]] = @[]
      for uri, diags in diagnosticMap.entries:
        entries.add([vscode.uriFile(uri).toJs(), diags.toJs()])
      diagnosticCollection.set(entries)
  )
  .catch(
    proc(reason: JsObject) =
      console.error("nimvscode - runCheck Failed", reason)
  )

proc startBuildOnSaveWatcher(subscriptions: Array[VscodeDisposable]) =
  vscode.workspace.onDidSaveTextDocument(
    proc(document: VscodeTextDocument) =
      if document.languageId != "nim":
        return

      var config = vscode.workspace.getConfiguration("nim")
      if config.getBool("lintOnSave"):
        runCheck(document)

      if config.getBool("buildOnSave"):
        vscode.commands.executeCommand("workbench.action.tasks.build")
    ,
    nil,
    subscriptions,
  )

proc runFile(ignore: bool, isDebug: bool = false): void =
  #TODO detect nim path
  let
    state = nimUtils.ext
    editor = vscode.window.activeTextEditor
    nimCfg = vscode.workspace.getConfiguration("nim")
    nimBuildCmdStr: cstring = state.getNimCmd() & nimCfg.getStr("buildCommand")
    runArg: cstring = if isDebug: " --debugger:native \"" else: " -r \""

  outputLine(fmt"[info] Running with Nim from {state.getNimCmd()}".cstring)
  if not editor.isNil():
    if terminal.isNil():
      terminal = vscode.window.createTerminal("Nim")
    terminal.show(true)

    if editor.document.isUntitled:
      terminal.sendText(
        nimBuildCmdStr & runArg & getDirtyFile(editor.document) & "\"", true
      )
    else:
      var
        outputDirConfig = nimCfg.getStr("runOutputDirectory")
        outputParams: cstring = ""
      if outputDirConfig.toJs().to(bool):
        if vscode.workspace.workspaceFolders.toJs().to(bool):
          var rootPath: cstring = ""
          let currentFileDir = path.dirname(editor.document.fileName)
          rootPath = currentFileDir
          for folder in vscode.workspace.workspaceFolders:
            if folder.uri.scheme == "file" and editor.document.fileName.startsWith(folder.uri.fsPath):
              rootPath = folder.uri.fsPath
              break
              
          if rootPath != "":
            let outputDir = path.join(rootPath, outputDirConfig)
            if not fs.existsSync(outputDir):
              fs.mkdirSync(outputDir, recursive = true)
            outputParams =
              " --out:\"" &
              path.join(outputDir, path.basename(editor.document.fileName, ".nim")
              ) & "\""

      if editor.toJs().to(bool) and editor.document.isDirty:
        editor.document.save().then(
          proc(success: bool): void =
            if not (terminal.isNil() or editor.isNil()) and success:
              terminal.sendText(
                nimBuildCmdStr & outputParams & runArg & editor.document.fileName & "\"",
                true,
              )
        )
      else:
        terminal.sendText(
          nimBuildCmdStr & outputParams & runArg & editor.document.fileName & "\"", true
        )

proc debugFile() =
  let
    config = vscode.workspace.getConfiguration("nim")
    outputDirConfig = config.getStr("runOutputDirectory")
    typ = config.getStr("debug.type")
    editor = vscode.window.activeTextEditor
    filename = editor.document.fileName
    currentFileDir = path.dirname(filename)
    
    # Use file's directory as fallback
    outputDir = if outputDirConfig.toJs().to(bool):
      let workspaceFolder = vscode.workspace.getWorkspaceFolder(editor.document.uri)
      if not workspaceFolder.isNil():
        path.join(workspaceFolder.uri.fsPath, outputDirConfig)
      else:
        path.join(currentFileDir, outputDirConfig)
    else:
      currentFileDir
      
    filePath = path.join(outputDir, path.basename(filename).replace(".nim", ""))
    workspaceFolder = vscode.workspace.getWorkspaceFolder(editor.document.uri)
  #compiles the file
  runFile(ignore = false, isDebug = true)
  let debugConfiguration = VsCodeDebugConfiguration(
    name: "Nim: " & filename, `type`: typ, request: "launch", program: filePath
  )
  discard vscode.debug.startDebugging(workspaceFolder, debugConfiguration).then(
      proc(success: bool) =
        console.log("Debugging started")
    )

proc onStartDebugSession(session: VscodeDebugSession) =
  ## load the nimprettylldb.py script into the debugger
  let dirname {.importjs: "__dirname".}: cstring
  let pyScriptPath = path.join(dirname, "../scripts/nimprettylldb.py")
  let cmd = cstring(&"command script import {pyScriptPath}")
  let arg = VscodeDebugExpression(expression: cmd, context: "repl")
  discard session.customRequest("evaluate", arg)

proc clearCachesCmd(): void =
  ## setup a command to clear file and type caches in case they're out of date
  let config = vscode.workspace.getConfiguration("files")
  discard clearCaches(config.getStrBoolMap("watcherExclude", defaultIndexExcludeGlobs))

proc setNimDir(state: ExtensionState) =
  #TODO allow the user specify a path in the settings
  #Exec nimble dump and extract the nimDir if it exists
  if not vscode.workspace.workspaceFolders.toJs().to(bool):
    return

  let path = vscode.workspace.workspaceFolders[0].uri.fsPath
  var process = cp.spawn(
    getNimbleExecPath(), @["dump".cstring], SpawnOptions(shell: true, cwd: path)
  )

  process.stdout.onData(
    proc(data: Buffer) =
      for line in splitLines($data.toString):
        if line.startsWith("nimDir"):
          state.nimDir = line[(1 + line.find '"') ..^ 2]
          outputLine(
            fmt"[info] Using NimDir from nimble dump. NimDir: {state.nimDir}".cstring
          )
        if line.startsWith("testEntryPoint"):
          state.dumpTestEntryPoint = line[(1 + line.find '"') ..^ 2]
          outputLine(
            fmt"[info] Using testEntryPoint from nimble dump. testEntryPoint: {state.dumpTestEntryPoint}".cstring
          )
  )


proc showNimLangServerStatus() {.async.} =
  let lspStatus = await fetchLspStatus(state)
  state.statusProvider.refresh(lspStatus)

proc showNimbleSetupDialog() =
  if not nimUtils.ext.config.getBool("nimbleAutoSetup"):
    return
  let editor = vscode.window.activeTextEditor
  if editor.isNil():
    return

  let document = editor.document
  let filePath = document.fileName
  let dirPath = path.dirname(filePath)
  
  # Check if there's a .nimble file in the directory
  var hasNimbleFile = false
  try:
    let files = fs.readdirSync(dirPath)
    for file in files:
      if ($file).endsWith(".nimble"):
        hasNimbleFile = true
        break
  except:
    return

  if not hasNimbleFile:
    return
    
  let nimblePathsFile = path.join(dirPath, "nimble.paths")
  if fs.existsSync(nimblePathsFile):
    return

  proc onClose(code: cint, signal: cstring): void =
    if code == 0:
      outputLine("nimble setup ran successfully")
      vscode.window.showInformationMessage("nimble setup ran successfully. A path file has been created with all the dependencies search paths.")
    else:
      outputLine("nimble setup failed")
  execNimbleCmd(@["setup".cstring], dirPath, onClose)

proc getNimCacheDir(): Future[Option[cstring]] {.async.} = 
  let editor = vscode.window.activeTextEditor
  if editor.isNil():
    return none(cstring)
    
  let currentFile = editor.document.fileName
  let cmd = state.getNimCmd()
  let args = @["dump".cstring, "--dump.format:json".cstring, currentFile]
  let process = cp.spawn(cmd, args, SpawnOptions(shell: true))
  var fullData = ""

  newPromise(
    proc(resolve: proc(response: Option[cstring]), reject: proc(reasons: Option[cstring])) =
      process.stdout.onData(proc(data: Buffer) =
        fullData.add($data.toString())
      )
  
      process.onClose(proc(code: cint, signal: cstring) =
        try:      
          let json = parseJson(fullData)
          let nimcache = json["nimcache"].getStr().cstring
          resolve(some(nimcache))
        except CatchableError:
          console.error("Error: " & getCurrentExceptionMsg().cstring)
          reject(none(cstring))
      )

      process.onError(proc(error: ChildError): void =
        console.error(error)
        reject(none(cstring))
      )
    
  )


proc getGeneratedFile(): Future[Option[cstring]] {.async.} = 
  let nimCacheDir = await getNimCacheDir()
  if nimCacheDir.isNone():
    return none(cstring)
  let nimcache = nimCacheDir.get()
  #checks forlder exists
  if not fs.existsSync(nimcache):
    return none(cstring)
  let currentFile = vscode.window.activeTextEditor.document.fileName
  let currentFileName = path.basename(currentFile)
  let files = fs.readdirSync(nimcache)
  for file in files:
    if currentFileName in file:
      let fullPath = path.join(nimcache, file)
      console.log("Generated file is " & fullPath)
      return some(fullPath)
  return none(cstring)


proc openGeneratedFile() {.async.} =
  showNimStatus("Opening generated file...", "nim.openGeneratedFile", "Opening generated file...")
  let generatedFile = await getGeneratedFile()
  if generatedFile.isSome():
    let fullPath = generatedFile.get()
    discard vscode.workspace.openTextDocument(vscode.uriFile(fullPath)).then(
      proc(doc: VscodeTextDocument) =
        discard vscode.window.showTextDocument(
                  doc,
                  VscodeTextDocumentShowOptions(
                    viewColumn: VscodeViewColumn.active # Opens in split view
                  )
                )    )
  else:
    console.log("No generated file found. Make sure the project is built.")
    vscode.window.showErrorMessage("No generated file found. Make sure the project is built.")
  hideNimStatus()

proc activate*(ctx: VscodeExtensionContext): void {.async.} =
  var config = vscode.workspace.getConfiguration("nim")
  state = ExtensionState(
    ctx: ctx,
    config: config,
    channel: vscode.window.createOutputChannel("Nim"),
    lspChannel: vscode.window.createOutputChannel("Nim Lsp"),
  )
  nimUtils.ext = state

  nimSuggestExec.extensionContext = ctx
  nimFormatting.extensionContext = ctx

  vscode.commands.registerCommand("nim.run.file", runFile)
  vscode.commands.registerCommand("nim.debug.file", debugFile)
  vscode.commands.registerCommand("nim.check", runCheck)
  vscode.commands.registerCommand(
    "nim.restartNimsuggest", () => onLspSuggest("restart", "current")
  )
  vscode.commands.registerCommand(
    "nim.execSelectionInTerminal", execSelectionInTerminal
  )
  vscode.commands.registerCommand("nim.clearCaches", clearCachesCmd)
  vscode.commands.registerCommand("nim.listCandidateProjects", listCandidateProjects)
  vscode.commands.registerCommand(
    "nim.showNimLangServerStatus", showNimLangServerStatus
  )
  vscode.commands.registerCommand("nim.showNotification", onShowNotification)
  vscode.commands.registerCommand("nim.onDeleteNotification", onDeleteNotification)
  vscode.commands.registerCommand(
    "nim.onClearAllNotifications", onClearAllNotifications
  )
  vscode.commands.registerCommand("nim.onNimbleTask", onNimbleTask)
  vscode.commands.registerCommand("nim.onRefreshNimbleTasks", refreshNimbleTasks)
  vscode.commands.registerCommand("nim.onLspSuggest", onLspSuggest)
  vscode.commands.registerCommand("nim.openGeneratedFile", openGeneratedFile)
  vscode.commands.registerCommand("nim.refreshTests", refreshTests)
  

  processConfig(config)
  discard vscode.workspace.onDidChangeConfiguration(configUpdate)
  vscode.debug.onDidStartDebugSession(onStartDebugSession)

  setNimDir(state)
  let provider = config.getStr("provider")

  if provider == "lsp":
    await startLanguageServer(true, state)
    state.statusProvider = newNimLangServerStatusProvider()
    discard vscode.window.registerTreeDataProvider("nim", state.statusProvider)
  elif provider == "nimsuggest" and config.getBool("enableNimsuggest"):
    initNimSuggest()
    ctx.subscriptions.add(
      vscode.languages.registerCompletionItemProvider(
        mode, nimCompletionItemProvider, ".", " "
      )
    )
    ctx.subscriptions.add(
      vscode.languages.registerDefinitionProvider(mode, nimDefinitionProvider)
    )
    ctx.subscriptions.add(
      vscode.languages.registerReferenceProvider(mode, nimReferenceProvider)
    )
    ctx.subscriptions.add(
      vscode.languages.registerRenameProvider(mode, nimRenameProvider)
    )
    ctx.subscriptions.add(
      vscode.languages.registerDocumentSymbolProvider(mode, nimDocSymbolProvider)
    )
    ctx.subscriptions.add(
      vscode.languages.registerSignatureHelpProvider(
        mode, nimSignatureProvider, "(", ","
      )
    )
    ctx.subscriptions.add(
      vscode.languages.registerHoverProvider(mode, nimHoverProvider)
    )
    ctx.subscriptions.add(
      vscode.languages.registerDocumentFormattingEditProvider(
        mode, nimFormattingProvider
      )
    )
  else:
    console.log("No backend selected.")

  diagnosticCollection = vscode.languages.createDiagnosticCollection("nim")
  ctx.subscriptions.add(diagnosticCollection)

  var languageConfig = VscodeLanguageConfiguration{
    # @Note Literal whitespace in below regexps is removed
    onEnterRules: newArrayWith[VscodeOnEnterRule](
      VscodeOnEnterRule{
        beforeText: newRegExp(r"^(\s)*## ", ""),
        action:
          VscodeEnterAction{indentAction: VscodeIndentAction.none, appendText: "## "},
      },
      VscodeOnEnterRule{
        beforeText: newRegExp(
          """
          ^\s*
          ( (case) \b .* : )
          \s*$
          """.replace(
            newRegExp(r"\s+?", r"g"), ""
          ),
          "",
        ),
        action: VscodeEnterAction{indentAction: VscodeIndentAction.none},
      },
      VscodeOnEnterRule{
        beforeText: newRegExp(
          """
          ^\s*
          (
            ((proc|macro|iterator|template|converter|func) \b .*=) |
            ((import|export|let|var|const|type) \b) |
            ([^:]+:)
          )
          \s*$
          """.replace(
            newRegExp(r"\s+?", r"g"), ""
          ),
          "",
        ),
        action: VscodeEnterAction{indentAction: VscodeIndentAction.indent},
      },
      VscodeOnEnterRule{
        beforeText: newRegExp(
          """
          ^\s*
          (
            ((return|raise|break|continue) \b .*) |
            ((discard) \b)
          )
          \s*
          """.replace(
            newRegExp(r"\s+?", r"g"), ""
          ),
          "",
        ),
        action: VscodeEnterAction{indentAction: VscodeIndentAction.outdent},
      },
    ),
    wordPattern: newRegExp(
      r"(-?\d*\.\d\w*)|([^\`\~\!\@\#\%\^\&\*\(\)\-\=\+\[\{\]\}\\\|\;\:\'\""\,\.\<\>\/\?\s]+)",
      r"g",
    ),
  }
  try:
    vscode.languages.setLanguageConfiguration(mode.language, languageConfig)
  except:
    console.error(
      "language configuration failed to set",
      getCurrentException(),
      getCurrentExceptionMsg().cstring,
    )

  vscode.window.onDidChangeActiveTextEditor(showHideStatus, nil, ctx.subscriptions)

  vscode.window.onDidCloseTerminal(
    proc(e: VscodeTerminal) =
      if terminal.toJs().to(bool) and e.processId == terminal.processId:
        terminal = nil
  )

  console.log(
    fmt"""
        ExtensionContext:
        extensionPath:{ctx.extensionPath}
        storagePath:{ctx.storagePath}
        logPath:{ctx.logPath}
      """.cstring.strip()
  )
  activateEvalConsole()
  if not fs.existsSync(ctx.storagePath):
    fs.mkdirSync(ctx.storagePath)

  let cfgFiles = vscode.workspace.getConfiguration("files")
  discard initWorkspace(
    ctx.storagePath, cfgFiles.getStrBoolMap("watcherExclude", defaultIndexExcludeGlobs)
  )

  fileWatcher = vscode.workspace.createFileSystemWatcher(cstring("**" / "*.nim"))
  fileWatcher.onDidCreate(
    proc(uri: VscodeUri) =
      var licenseString = config.getStr("licenseString")
      if not licenseString.isNil() and licenseString != "":
        var path = uri.fsPath.toLowerAscii()
        if path.endsWith(".nim") or path.endsWith(".nims"):
          fs.stat(
            uri.fsPath,
            proc(err: ErrnoException, stats: FsStats) =
              var edit = vscode.newWorkspaceEdit()
              edit.insert(uri, vscode.newPosition(0, 0), licenseString)
              vscode.workspace.applyEdit(edit),
          )
      discard addFileToImports(uri.fsPath)
  )
  fileWatcher.onDidDelete(
    proc(uri: VscodeUri) =
      discard removeFileFromImports(uri.fsPath)
  )

  ctx.subscriptions.add(
    vscode.languages.registerWorkspaceSymbolProvider(nimWsSymbolProvider)
  )

  startBuildOnSaveWatcher(ctx.subscriptions)

  if vscode.window.activeTextEditor.toJs().to(bool) and config.getBool("lintOnSave"):
    runCheck(vscode.window.activeTextEditor.document)

  if config.getBool("enableNimsuggest") and config.getInt("nimsuggestRestartTimeout") > 0:
    var timeout = config.getInt("nimsuggestRestartTimeout")
    console.log(fmt"Reset nimsuggest process each {timeout} minutes".cstring)
    global.setInterval(
      proc() =
        discard closeAllNimsuggestProcesses(),
      timeout * 60000,
    )

  discard initImports()
  outputLine("[info] Extension Activated")
  showNimbleSetupDialog()

  let nimbleCodeLensProvider = newCodeLensProvider(provideNimbleTasksCodeLenses)
  ctx.subscriptions.add(
    vscode.languages.registerCodeLensProvider(
      VscodeDocumentFilter(language: "nimble", scheme: "file"),
      nimbleCodeLensProvider
    )
  )

  # Watch for .nimble files
  let nimbleWatcher = vscode.workspace.createFileSystemWatcher("**/*.nimble")
  nimbleWatcher.onDidChange(proc(uri: VscodeUri) =
    # console.log("*********nimbleWatcher.onDidChange called", uri)
    if uri.path == vscode.window.activeTextEditor.document.uri.path:
      discard refreshNimbleTasks()
    #TODO update tasks here
      # provideNimbleTasksDecorations(ctx, vscode.window.activeTextEditor.document)
  )
  ctx.subscriptions.add(nimbleWatcher)
  initializeTests(ctx, nimUtils.ext)

  # Register nimlangserver as an MCP server provider.
  let
    mcpProvider = McpServerDefinitionProvider{
      provideMcpServerDefinitions: proc(): seq[McpStdioServerDefinition] =
        @[
          newMcpStdioServerDefinition(
            vscode,
            "Nim Language Server",
            "nimlangserver",
            @["--mcp".cstring]
          )
        ]
    }

  ctx.subscriptions.add(
    vscode.lm.registerMcpServerDefinitionProvider(
      "nimlangserver",
      mcpProvider
    )
  )

proc deactivate*(): void {.async.} =
  let provider = nimUtils.ext.config.getStr("provider")
  if provider == "lsp":
    await stopLanguageServer(nimUtils.ext)
  discard onClose()
  discard closeAllNimSuggestProcesses()
  fileWatcher.dispose()

var module {.importc.}: JsObject
module.exports.activate = activate
module.exports.deactivate = deactivate
