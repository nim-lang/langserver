import std/[jsconsole, strformat, strutils, options, sequtils]
import platform/[vscodeApi, languageClientApi]
import spec, nimUtils
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
      command.command = "nim.onNimbleTask"
      command.title = "$(play-circle) Run task"
      command.arguments = @[taskName.get.toJs()]
      result.add(vscode.newCodeLens(range, command))
    inc line