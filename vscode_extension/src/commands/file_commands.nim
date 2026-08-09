import platform/vscodeApi
import platform/js/[jsre, jsString, jsNodeFs, jsNodePath, jsNodeCp]
import std/[strformat, jsconsole, strutils, options, json]
import ../tools/nimUtils
import ../state/state_types
import ../state/state
import ../status_panel/nimStatus

var terminal {.threadvar.}: VscodeTerminal

proc initTerminalHandlers*() =
  vscode.window.onDidCloseTerminal(
    proc(e: VscodeTerminal) =
      if terminal.toJs().to(bool) and e.processId == terminal.processId:
        terminal = nil
  )

proc runFile*(ignore: bool, isDebug: bool = false): void =
  #TODO detect nim path
  let
    state = nimUtils.ext
    editor = vscode.window.activeTextEditor
    nimCfg = vscode.workspace.getConfiguration("nimTortoise")
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


proc debugFile*() =
  let
    config = vscode.workspace.getConfiguration("nimTortoise")
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

proc getNimCacheDir(): Future[Option[cstring]] {.async.}

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


proc openGeneratedFile*() {.async.} =
  showNimStatus("Opening generated file...", "nimTortoise.openGeneratedFile", "Opening generated file...")
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

proc getNimCacheDir(): Future[Option[cstring]] {.async.} = 
  let editor = vscode.window.activeTextEditor
  if editor.isNil():
    return none(cstring)
    
  let currentFile = editor.document.fileName
  let cmd = nimUtils.ext.getNimCmd()
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
