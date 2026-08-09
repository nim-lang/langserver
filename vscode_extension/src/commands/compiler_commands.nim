import platform/vscodeApi
import platform/js/[jsNodeCp, jsNodeOs, jsString, jsre]
import std/[jsconsole, sequtils]
from std/strformat import fmt
import ../tools/nimUtils
from project_commands import getProjects, isProjectMode, getProjectFileInfo,
                             ProjectFileInfo, toLocalFile
from tools/nimBinTools import getNimExecPath

var evalTerminal: VscodeTerminal

# This is a "run arbitrary code snippets" feature. It takes your selected text (or current line), opens a terminal running either nim secret (Nim's built-in REPL) or inim (a third-party Nim REPL), and sends the text to it. The maintainIndentation helper fixes up indentation so pasted blocks are valid at the top level.

proc activateEvalConsole*(): void =
  vscode.window.onDidCloseTerminal(proc(e: VscodeTerminal) =
    if not evalTerminal.isNil() and e.processId == evalTerminal.processId:
      evalTerminal = jsUndefined.to(VscodeTerminal)
  )

proc selectTerminal(): Future[cstring] {.async.} =
  let items = newArrayWith[VscodeQuickPickItem](
    VscodeQuickPickItem{
      label: "nim",
      description: "Using `nim secret` command"
    },
    VscodeQuickPickItem{
      label: "inim",
      description: "Using `inim` command"
    }
  )
  var quickPick = await vscode.window.showQuickPick(items)
  return if quickPick.isNil(): jsUndefined.to(cstring) else: quickPick.label

proc nextLineWithTextIdentation(startOffset: cint, tmp: seq[cstring]): cint =
  for i in startOffset..<tmp.len:
    # Empty lines are ignored
    if tmp[i] == "": continue

    # Spaced line, this is indented
    var m = tmp[i].match(newRegExp(r"^ *"))
    if m.toJs().to(bool) and m[0].len > 0:
      return cint(m[0].len)

    # Normal line without identation
    break
  return 0

proc maintainIndentation(text: cstring): cstring =
  var tmp = text.split(newRegExp(r"\r?\n"))

  if tmp.len <= 1:
    return text

  # if previous line is indented, this line is empty
  # and next line with text is indented then this line should be indented
  for i in 0..(tmp.len - 2):
    # empty line
    if tmp[i].len == 0:
      var spaces = nextLineWithTextIdentation(cint(i + 1), tmp)
      # Further down, there is an indented line, so this empty line
      # should be indented
      if spaces > 0:
        tmp[i] = cstring(" ").repeat(spaces)

  return tmp.join("\n")

proc execSelectionInTerminal*(#[ doc:VscodeTextDocument ]#) {.async.} =
  var activeEditor = vscode.window.activeTextEditor
  if not activeEditor.isNil():
    var selection = activeEditor.selection
    var document = activeEditor.document
    var text = if selection.isEmpty:
                document.lineAt(selection.active.line).text
            else:
                document.getText(selection)

    if evalTerminal.isNil():
      # select type of terminal
      var executable = await selectTerminal()

      if executable.isNil():
        return

      var execPath = getNimExecPath(executable)
      if execPath.isNil() or execPath.strip() == "":
        vscode.window.showInformationMessage(
          fmt"Binary named '{executable}' not found in PATH environment variable".cstring
        )
        return
      evalTerminal = vscode.window.createTerminal("Nim Console")
      evalTerminal.show(preserveFocus = true)
      # previously was a setTimeout 3s, perhaps a valid pid works better
      discard await evalTerminal.processId

      if executable == "nim":
        evalTerminal.sendText(execPath & " secret\n")
      elif executable == "inim":
        evalTerminal.sendText(execPath & " --noAutoIndent\n")

    evalTerminal.sendText(maintainIndentation(text))
    evalTerminal.sendText("\n")
