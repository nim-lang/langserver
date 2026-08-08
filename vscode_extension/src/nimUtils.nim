## Used by various features (`nim*` files) as a catch-all file for common procs

import platform/vscodeApi
import platform/js/[jsNodeFs, jsNodePath, jsString]
import std/[jscore, strformat, sequtils, hashes, os]

import spec

var ext*: ExtensionState

# Bridging code while refactoring state around - start

template extensionContext(): VscodeExtensionContext =
  ext.ctx

template channel(): VscodeOutputChannel =
  ext.channel

# Bridging code while refactoring state around - end

proc isSubpath(parent, child: cstring): bool =
  result =
    if process.platform == "win32":
      child.toLowerAscii.startsWith(parent.toLowerAscii)
    else:
      child.startsWith(parent.toLowerAscii)

proc isWorkspaceFile*(filePath: cstring): bool =
  ## Returns true if filePath is related to any workspace file
  ## assumes filePath is absolute

  if vscode.workspace.workspaceFolders.toJs().to(bool):
    return vscode.workspace.workspaceFolders.anyIt(
      it.uri.scheme == "file" and isSubpath(it.uri.fsPath, filePath)
    )
  else:
    return false

proc removeDirSync(p: cstring): void =
  if fs.existsSync(p):
    for entry in fs.readdirSync(p):
      var curPath = path.resolve(p, entry)
      if fs.lstatSync(curPath).isDirectory():
        removeDirSync(curPath)
      else:
        fs.unlinkSync(curPath)
    fs.rmdirSync(p)

proc getDirtyFileFolder*(nimsuggestPid: cint): cstring =
  path.join(extensionContext.storagePath, "vscodenimdirty_" & cstring($nimsuggestPid))

proc cleanupDirtyFileFolder*(nimsuggestPid: cint) =
  removeDirSync(getDirtyFileFolder(nimsuggestPid))

proc getDirtyFile*(nimsuggestPid: cint, filepath, content: cstring): cstring =
  ## temporary file path of edited document
  ## for each nimsuggest instance each file has a unique dirty file
  var dirtyFilePath = path.normalize(
    path.join(getDirtyFileFolder(nimsuggestPid), cstring($int(hash(filepath))) & ".nim")
  )
  fs.writeFileSync(dirtyFilePath, content)
  return dirtyFilePath

proc getDirtyFile*(doc: VscodeTextDocument): cstring =
  ## temporary file path of edited document
  ## returns always the same file, so it shouldn't
  ## be used for nimsuggest, only nimpretty!
  var dirtyFilePath =
    path.normalize(path.join(extensionContext.storagePath, "vscodenimdirty.nim"))
  fs.writeFileSync(dirtyFilePath, doc.getText())
  return dirtyFilePath

proc padStart(len: cint, input: cstring): cstring =
  var output = cstring("0").repeat(input.len)
  return output & input

proc cleanDateString(date: DateTime): cstring =
  var year = date.getFullYear()
  var month = padStart(2, cstring($(date.getMonth())))
  var dd = padStart(2, cstring($(date.getDay())))
  var hour = padStart(2, cstring($(date.getHours())))
  var minute = padStart(2, cstring($(date.getMinutes())))
  var second = padStart(2, cstring($(date.getSeconds())))
  var milliseconds = padStart(3, cstring($(date.getMilliseconds())))
  return cstring(fmt"{year}-{month}-{dd} {hour}:{minute}:{second}.{milliseconds}")

proc outputLine*(message: cstring): void =
  ## Prints message in Nim's output channel
  channel.appendLine(fmt"{cleanDateString(newDate())} - {message}".cstring)

proc quoteOnlyWin*(path: cstring): cstring = 
  result = path
  if process.platform == "win32":
    result = quoteShellWindows($path).cstring