## Executes, manages, and coordinates between the extension and nimsuggest

import platform/vscodeApi
import platform/js/[jsNodeCp, jsNodePath, jsNodeFs, jsre, jsString]

import std/[sequtils, jsconsole]
from std/dom import isNaN
from std/strformat import fmt

import tools/elrpc
import nimsuggest/sexp

import nimUtils
from nimProjects import isProjectMode, toLocalFile, getProjectFileInfo, ProjectFileInfo
from tools/nimBinTools import getBinPath

type NimSuggestProcessDescription* = ref object
  process*: ChildProcess
  rpc*: EPCPeer

var nimSuggestPath: cstring
var nimSuggestVersion: cstring
var nimSuggestProcessCache = newMap[cstring, Future[NimSuggestProcessDescription]]()
var extensionContext*: VscodeExtensionContext

type NimSuggestType* {.nodecl.} = enum
  sug = 0
  con = 1
  def = 2
  use = 3
  dus = 4
  chk = 5
  highlight = 6
  outline = 7
  known = 8

type NimSuggestResult* = ref object
  names*: seq[cstring]
  answerType*: cstring
  suggest*: cstring
  `type`*: cstring
  path*: cstring
  line*: cint
  column*: cint
  documentation*: cstring

proc `range`*(r: NimSuggestResult): VscodeRange =
  vscode.newRange(cint(r.line - 1), r.column, cint(r.line - 1), r.column)

proc position*(r: NimSuggestResult): VscodePosition =
  vscode.newPosition(cint(r.line - 1), r.column)

proc uri*(r: NimSuggestResult): VscodeUri =
  vscode.uriFile(r.path)

proc location*(r: NimSuggestResult): VscodeLocation =
  vscode.newLocation(r.uri, r.position)

proc fullName*(r: NimSuggestResult): cstring =
  if r.names.toJs().to(bool):
    r.names.join(".")
  else:
    ""

proc symbolName*(r: NimSuggestResult): cstring =
  if r.names.toJs().to(bool):
    r.names[r.names.len - 1]
  else:
    ""

proc moduleName*(r: NimSuggestResult): cstring =
  if r.names.toJs().to(bool):
    r.names[0]
  else:
    ""

proc containerName*(r: NimSuggestResult): cstring =
  if r.names.toJs().to(bool):
    r.names[0 ..^ 2].join(".")
  else:
    ""

proc getNimSuggestPath*(): cstring =
  nimSuggestPath

proc getNimSuggestVersion*(): cstring =
  nimSuggestVersion

proc initNimSuggest*() =
  # check nimsuggest related executable
  var nimSuggestNewPath = path.resolve(getBinPath("nimsuggest"))

  if fs.existsSync(nimSuggestNewPath):
    nimSuggestPath = nimSuggestNewPath
    var versionOutput = cp
      .spawnSync(
        getNimSuggestPath(),
        @["--version".cstring],
        SpawnSyncOptions{cwd: extensionContext.extensionPath},
      ).output
      .join(",".cstring)
    var versionArgs =
      newRegExp(r".+Version\s([\d|\.]+)\s\(.+", r"g").exec(versionOutput)

    if versionArgs.toJs().to(bool) and versionArgs.len == 2:
      nimSuggestVersion = versionArgs[1]

    console.log(versionOutput)
    console.log("Nimsuggest version: " & nimSuggestVersion)

proc isNimSuggestVersion*(version: cstring): bool =
  ## Returns true if nimsuggest version is greater or equal to version

  if nimSuggestVersion.isNull() or nimSuggestVersion.isUndefined():
    return false

  var nimVersionParts = nimSuggestVersion.split(".")
  var versionParts = version.split(".")
  for i in 0 .. min(nimVersionParts.len, versionParts.len):
    var nimVer = parseCint(nimVersionParts[i])
    var ver = parseCint(versionParts[i])
    var diff = nimVer - ver

    if diff == 0:
      continue
    return diff > 0
  return true

proc trace(pid: cint, projectFile: cstring, msg: JsObject): void =
  var log =
    vscode.workspace.getConfiguration("nim").get("logNimsuggest").toJs().to(bool)
  if log:
    if projectFile.toJs().jsTypeOf() == "string":
      console.log("[" & cstring($pid) & ":" & projectFile & "]")
    console.log(msg)

proc trace(pid: cint, projectFile: ProjectFileInfo, msg: JsObject): void =
  var str =
    projectFile.wsFolder.name & ":" & projectFile.wsFolder.uri.fsPath & ":" &
    projectFile.filePath
  trace(pid, str, msg)

proc closeCachedProcess(desc: NimSuggestProcessDescription): void =
  if desc.toJs().to(bool):
    try:
      if desc.rpc.toJs().to(bool):
        desc.rpc.stop()
    finally:
      if desc.process.toJs().to(bool):
        desc.process.kill()

proc closeNimsuggestProcess*(file: cstring) {.async.} =
  var process = nimSuggestProcessCache[file]
  if process.toJs().to(bool):
    try:
      var desc = await process
      let pid = desc.process.pid

      try:
        cleanupDirtyFileFolder(pid)
      except:
        console.log("cleanupDirtyFileFolder failed - ignorable", pid)

      closeCachedProcess(desc)
    except:
      console.error("closeCachedProcess failed", getCurrentException())
    finally:
      nimSuggestProcessCache[file] =
        jsUndefined.to(Promise[NimSuggestProcessDescription])
      discard nimSuggestProcessCache.delete(file)

proc closeNimsuggestProcess*(project: ProjectFileInfo) {.async.} =
  await closeNimsuggestProcess(toLocalFile(project))

proc closeAllNimSuggestProcesses*() {.async.} =
  console.log("Close all nimsuggest processes")
  for project in nimSuggestProcessCache.keys():
    try:
      await closeNimsuggestProcess(project)
    except:
      console.error("failed to close", getCurrentException())

proc getNimSuggestProcess(
    nimProject: ProjectFileInfo
): Future[NimSuggestProcessDescription] =
  var projectPath = toLocalFile(nimProject)
  if nimSuggestProcessCache[projectPath].isNil():
    nimSuggestProcessCache[projectPath] = newPromise(
      proc(
          resolve: proc(s: NimSuggestProcessDescription), reject: proc(reason: JsObject)
      ) =
        var nimConfig = vscode.workspace.getConfiguration("nim")
        var args = @["--epc".cstring, "--v2".cstring]
        if nimConfig.getBool("logNimsuggest"):
          args.add("--log".cstring)
        if nimConfig.getBool("useNimsuggestCheck"):
          args.add("--refresh:on".cstring)

        args.add(nimProject.filePath)
        var cwd = nimProject.wsFolder.uri.fsPath
        var process = cp.spawn(getNimsuggestPath(), args, SpawnOptions{cwd: cwd})
        console.log(
          fmt"started nimsuggest process ({process.pid})) args: ({args.join("" "")}) cwd: {cwd} nim project:".cstring,
          nimProject,
        )
        process.stdout.onceData(
          proc(data: Buffer) =
            var dataStr = data.toString()
            var portNumber = parseCint(dataStr)
            if isNaN(portNumber.toJs().to(float64)):
              reject((fmt"Nimsuggest return unknown port number: {dataStr}").toJs())
            else:
              startClient(process.pid, portNumber).then(
                proc(peer: EPCPeer) =
                  resolve(NimSuggestProcessDescription{process: process, rpc: peer})
              )
        )
        process.stdout.onceData(
          proc(data: Buffer) =
            console.log(
              "getNimSuggestProcess - stdout pid: ",
              process.pid,
              "data:",
              data.toString(),
            )
        )
        process.stderr.onceData(
          proc(data: Buffer) =
            console.log(
              "getNimSuggestProcess - stderr pid: ",
              process.pid,
              "data:",
              data.toString(),
            )
        )
        process.onClose(
          proc(code: cint, signal: cstring): void =
            cleanupDirtyFileFolder(process.pid)
            let
              codeStr =
                if code.toJs().isNull():
                  "unknown"
                else:
                  $(code)
              signalStr =
                if signal == nil:
                  "null"
                else:
                  $signal
              msg =
                fmt"nimsuggest {process.pid} (args: {args.join("" "")}) closed with code: {codeStr} and signal: {signalStr}"
            if code != 0:
              console.error(msg.cstring)
            else:
              console.log(msg.cstring)
            if nimSuggestProcessCache[projectPath].toJs().to(bool):
              nimSuggestProcessCache[projectPath]
              .then(
                proc(desc: NimSuggestProcessDescription) =
                  if desc.toJs().to(bool) and desc.rpc.toJs().to(bool):
                    desc.rpc.stop()
              )
              .catch(
                proc(reason: JsObject) =
                  console.error("nimSuggestExec - getNimSuggestProcess Failed", reason)
              )
            reject(msg.toJs())
        )

        fs.mkdirSync(getDirtyFileFolder(process.pid))
    )
  return nimSuggestProcessCache[projectPath]

proc restartNimsuggest(project: ProjectFileInfo): Future[void] {.async.} =
  await closeNimsuggestProcess(project)
  discard getNimSuggestProcess(project)

proc restartNimsuggest*(): void =
  let doc = vscode.window.activeTextEditor.document
  if not doc.isNil():
    let provider = vscode.workspace.getConfiguration("nim").getStr("provider")
    if provider == "nimsuggest":
      discard restartNimsuggest(getProjectFileInfo(doc.fileName))

proc execNimSuggest*(
    suggestType: NimSuggestType,
    filename: cstring,
    line: cint,
    column: cint,
    useDirtyFile: bool,
    dirtyFileContent: cstring = "",
): Future[seq[NimSuggestResult]] {.async.} =
  var nimSuggestExec = getNimSuggestPath()
  var ret: seq[NimSuggestResult] = @[]

  # if nimsuggest not found just ignore
  if not nimSuggestExec.toJs().to(bool):
    return ret

  # don't run nimsuggest for nims file or cfg
  # See https://github.com/pragmagic/vscode-nim/issues/84
  var ext = path.extname(filename).toLowerAscii()
  if ext == ".nims" or ext == ".cfg":
    return ret

  var projectFile = getProjectFileInfo(filename)
  console.log("execNimSuggest - filename", filename, "projectFile", projectFile)

  try:
    var normalizedFilename: cstring = filename.replace(newRegExp(r"\\+", r"g"), "/")
    var desc = await getNimSuggestProcess(projectFile)
    var suggestCmd: cstring = cstring($suggestType)
    var isValidDesc = desc.toJs().to(bool)
    var dirtyFile = cstring ""

    if useDirtyFile:
      dirtyFile = getDirtyFile(desc.process.pid, filename, dirtyFileContent)

    if isValidDesc and desc.process.toJs().to(bool):
      trace(
        desc.process.pid,
        projectFile,
        (
          suggestCmd & " " & normalizedFilename & ":" & cstring($line) & ":" &
          cstring($column)
        ).toJs(),
      )

    if isValidDesc and desc.rpc.toJs().to(bool):
      console.log(
        "nimsuggest method call - ", desc.process.pid, suggestCmd, normalizedFilename,
        dirtyFile,
      )

      var sexps =
        @[sexp($(normalizedFilename)), sexp(line), sexp(column), sexp($(dirtyFile))]
      var r = await desc.rpc.callMethod(suggestCmd, sexps)

      if desc.process.toJs().to(bool):
        trace(
          desc.process.pid,
          toLocalFile(projectFile) & "=" & suggestCmd & " " & normalizedFilename,
          r.toJs(),
        )

      if r.toJs().isJsArray():
        for parts in r.mapIt(it.getElems()).filterIt(it.len >= 8):
          var doc = cstring(parts[7].getStr())
          if doc != "":
            doc = doc.replace(newRegExp(r"``", r"g"), "`")
            doc = doc.replace(
              newRegExp(r"\.\. code-block:: (\w+)\r?\n(( .*\r?\n?)+)", r"g"),
              "```$1\n$2\n```\n",
            )
            doc = doc.replace(
              newRegExp(r"`([^\<`]+)\<([^\>]+)\>`\_", r"g"), r"\[$1\]\($2\)"
            )
          var item = NimSuggestResult{
            answerType: cstring(parts[0].getStr()),
            suggest: cstring(parts[1].getStr()),
            names: parts[2].getElems().mapIt(cstring(it.getStr())),
            path: cstring(parts[3].getStr()).replace(newRegExp(r"\\,\\", r"g"), r"\"),
            `type`: cstring(parts[4].getStr()),
            line: cint(parts[5].getNum()),
            column: cint(parts[6].getNum()),
            documentation: doc,
          }
          ret.add(item)
      elif r.toJs().to(cstring) == "EPC Connection closed":
        console.error("execNimSuggest failed, EPC Connection closed", ret)
        await closeNimsuggestProcess(projectFile)
      else:
        ret.add(NimSuggestResult{suggest: "" & r.toJs().to(cstring)})

    var nonProjectAndFileClosed =
      not isProjectMode() and
      vscode.window.visibleTextEditors.allIt(it.document.uri.fsPath != filename)
    if nonProjectAndFileClosed:
      await closeNimsuggestProcess(projectFile)

    return ret
  except:
    console.error(
      "Error in execNimSuggest: ",
      getCurrentException(),
      getCurrentExceptionMsg().cstring,
    )
    await closeNimsuggestProcess(projectFile)
