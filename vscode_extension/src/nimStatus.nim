## shows status and progress for the extension
## XXX: the way we're using status goes against the vscode guidelines, they
##      have specific status vs progress indicator guidance and we're spamming
##      the api, this should get reworked.

import platform/vscodeApi
import std/jsconsole

import nimMode

var statusBarEntry: VscodeStatusBarItem
var progressBarEntry: VscodeStatusBarItem

proc showHideStatus*(): void =
  if statusBarEntry.isNil():
    return

  if vscode.window.activeTextEditor.isNil():
    statusBarEntry.hide()
    return

  if vscode.languages.match(mode, vscode.window.activeTextEditor.document) > 0:
    statusBarEntry.show()
    return

  statusBarEntry.hide()

proc hideNimStatus*() =
  statusBarEntry.dispose()

proc hideNimProgress*() =
  progressBarEntry.dispose()

proc showNimStatus*(msg: cstring, cmd: cstring, tooltip: cstring): void =
  statusBarEntry =
    vscode.window.createStatusBarItem(VscodeStatusBarAlignment.right, numberMinValue)
  statusBarEntry.text = msg
  statusBarEntry.command = cmd
  statusBarEntry.color = "yellow"
  statusBarEntry.tooltip = tooltip
  statusBarEntry.show()

proc showNimProgress*(msg: cstring): void =
  progressBarEntry =
    vscode.window.createStatusBarItem(VscodeStatusBarAlignment.right, numberMinValue)
  console.log(msg)
  progressBarEntry.text = msg
  progressBarEntry.tooltip = msg
  progressBarEntry.show()

proc updateNimProgress*(msg: cstring): void =
  progressBarEntry.text = msg
