## this extension ain't pretty, but maybe your code might be? This works with
## nim pretty to clean things up.

import platform/vscodeApi
import platform/js/[jsNodeCp, jsNodeFs]

import std/jsconsole
from std/strformat import fmt

import nimUtils
from tools/nimBinTools import getNimPrettyExecPath

var extensionContext*: VscodeExtensionContext

proc provideDocumentFormattingEdits*(
    doc: VscodeTextDocument,
    options: VscodeFormattingOptions,
    token: VscodeCancellationToken,
): Future[seq[VscodeTextEdit]] {.async.} =
  var ret: seq[VscodeTextEdit] = @[]
  if getNimPrettyExecPath() == "":
    vscode.window.showInformationMessage(
      "No 'nimpretty' binary could be found in PATH environment variable"
    )
    return ret

  var file = getDirtyFile(doc)
  var config = vscode.workspace.getConfiguration("nim")
  var res = cp.spawnSync(
    getNimPrettyExecPath(),
    @[
      cstring "--backup:OFF",
      "--indent:" & cstring($(config.getInt("nimprettyIndent"))),
      "--maxLineLen:" & cstring($(config.getInt("nimprettyMaxLineLen"))),
      file,
    ],
    SpawnSyncOptions{cwd: extensionContext.extensionPath},
  )

  if res.status != 0:
    console.error("Formatting failed:", res.error)
    {.emit: "throw `res`.error;".}
  elif not fs.existsSync(file):
    var msg: cstring = fmt"Formatting failed - file not found: {file}".cstring
    console.error(msg)
    {.emit: "throw { message: `msg` }".}
    return ret

  var content = fs.readFileSync(file, "utf-8")
  var `range` = doc.validateRange(
    vscode.newRange(vscode.newPosition(0, 0), vscode.newPosition(1000000, 1000000))
  )
  ret.add(vscode.textEditReplace(`range`, content))
  return ret

var nimFormattingProvider* {.exportc.} = block:
  var o = newJsObject()
  o.provideDocumentFormattingEdits = provideDocumentFormattingEdits
  o.to(VscodeDocumentFormattingEditProvider)
