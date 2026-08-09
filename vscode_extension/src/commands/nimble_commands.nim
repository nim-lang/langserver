import std/[jsconsole, strformat, strutils, options, sequtils]
import platform/[vscodeApi, languageClientApi]
import platform/js/[jsNodeFs, jsNodePath]
import ../state/state_types
import ../tools/nimUtils
from ../tools/nimBinTools import execNimbleCmd

proc showNimbleSetupDialog*() =
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

# ===  Nimble Code Lenses ===
# TODO gutter icons doesnt support click https://github.com/microsoft/vscode/issues/224134
# Review at some point and use that instead of codelenses.

proc parseIconPath(vscode: Vscode, iconPath: cstring): VscodeUri {.importjs: "#.Uri.parse(#)".}

proc lineAsTask(state: ExtensionState, lineText: string): Option[cstring] =
  result = none(cstring)
  try:
    let taskName = lineText.split(" ")[1].split(",")[0].cstring
    if taskName in state.nimbleTasks.mapIt(it.name):
      return some(taskName)
  except: discard

proc provideNimbleTasksCodeLenses*(document: VscodeTextDocument, token: VscodeCancellationToken): seq[VscodeCodeLens] =
  result = @[]
  if not ($document.fileName).endsWith(".nimble"):
    return
  let state = ext
  var line = 0
  let text = $document.getText()
  #TODO parse this properly
  for lineText in text.split("\n"):
    let taskName = lineAsTask(state, lineText)
    if taskName.isSome:
      let range = vscode.newRange(line, 0, line, 0)
      let command = VscodeCommands()
      let dirPath = path.dirname(document.fileName)
      command.command = "nimTortoise.onNimbleTask"
      command.title = "$(play-circle) Run task"
      command.arguments = @[taskName.get.toJs(), dirPath.toJs()]
      result.add(vscode.newCodeLens(range, command))
    inc line