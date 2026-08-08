## does the work to build whatever file the user is asking for or running a
## nim check and handling the diagnostics.

import platform/vscodeApi
import platform/js/[jsNodeCp, jsNodeOs, jsString, jsre]
import std/[jsconsole, sequtils]
from std/strformat import fmt
import nimSuggestExec, nimUtils
from nimProjects import getProjects, isProjectMode, getProjectFileInfo,
                        ProjectFileInfo, toLocalFile
from tools/nimBinTools import getNimExecPath

type
  CheckStacktrace* = ref object
    file*: cstring
    line*: cint
    column*: cint
    msg*: cstring

  CheckResult* = ref object
    file*: cstring
    line*: cint
    column*: cint
    msg*: cstring
    severity*: cstring
    stacktrace*: seq[CheckStacktrace]

  ExecutorStatus = ref object
    initialized: bool
    process: ChildProcess

var executors = newJsAssoc[cstring, ExecutorStatus]()

proc nimExec(
    project: ProjectFileInfo,
    cmd: cstring,
    args: seq[cstring],
    useStdErr: bool,
    cb: (proc(lines: seq[cstring]): seq[CheckResult])
): Promise[seq[CheckResult]] =
  return newPromise(proc(
        resolve: proc(results: seq[CheckResult]),
        reject: proc(reason: JsObject)
    ) =
    var execPath = getNimExecPath()
    if execPath.isNil() or execPath.strip() == "":
      vscode.window.showInformationMessage(
        "Binary named 'nim' not found in PATH environment variable"
      )
      resolve(@[])
      return

    var projectPath = toLocalFile(project)
    var executorStatus = executors[projectPath]
    if(not executorStatus.isNil() and executorStatus.initialized):
      var ps = executorStatus.process
      executors[projectPath] = ExecutorStatus{
          initialized: false, process: jsUndefined.to(ChildProcess)
      }
      if not ps.isNil():
        ps.kill("SIGKILL")
    else:
      executors[projectPath] = ExecutorStatus{
          initialized: false, process: jsUndefined.to(ChildProcess)
      }

    var executor = cp.spawn(
            execPath,
            @[cmd] & args,
            SpawnOptions{cwd: project.wsFolder.uri.fsPath}
      )
    executors[projectPath].process = executor
    executors[projectPath].initialized = true

    executor.onError(proc(error: ChildError): void =
      if not error.isNil() and error.code == "ENOENT":
        vscode.window.showInformationMessage(
            "No nim binary could be found in PATH: '" & process.env["PATH"] & "'"
        )
        resolve(@[])
        return
    )

    executor.stdout.onData(proc(data: Buffer) =
      outputLine("[info] nim check output:\n" & data.toString())
    )

    var output: cstring = ""
    executor.onExit(proc(code: cint, signal: cstring) =
      if signal == "SIGKILL":
        reject(jsNull)
      else:
        executors[projectPath] = ExecutorStatus{
            initialized: false,
            process: jsUndefined.to(ChildProcess)
        }

        try:
          var split: seq[cstring] = output.split(nodeOs.eol)
          if split.len == 1:
            # TODO - is this a bug by not using os.eol??
            var lfSplit = split[0].split("\n")
            if lfSplit.len > split.len:
              split = lfSplit

          resolve(cb(split))
        except:
          reject(getCurrentException().toJs())
    )

    if useStdErr:
      executor.stderr.onData(proc(data: Buffer) =
        output &= data.toString()
      )
    else:
      executor.stdout.onData(proc(data: Buffer) =
        output &= data.toString()
      )
  ).catch(proc(reason: JsObject): Promise[seq[CheckResult]] =
    console.error("nim check failed", reason)
    return promiseReject(reason).toJs().to(Promise[seq[CheckResult]])
  )

proc parseErrors(lines: seq[cstring]): seq[CheckResult] =
  var
    messageText = ""
    stacktrace: seq[CheckStacktrace]
    lastFile, lastLineStr, lastCharStr: cstring

  # Progress indicator from nim CLI is just dots
  var dots = newRegExp(r"^\.+$")
  for line in lines:
    let line = line.strip()

    if line.startsWith("Hint:") or line == "" or dots.test(line):
      continue

    let match = newRegExp(r"^(>+ )?([^(]*)?\((\d+)(,\s(\d+))?\)( (\w+):)? (.*)")
      .exec(line)
    if not match.toJs().to(bool):
      if messageText.len < 1024:
        messageText &= nodeOs.eol & line
    else:
      let
        severity = match[7]
        msg = match[8]
      # file may be undefined when there's an error in code
      # created with parseExpr/parseStmt
      # as a workaround we duplicate the last location in the stacktrace
      # There always has to be atleast the location where the macro
      # called which contains the faulty parseExpr/parseStmt
        (file, lineStr, charStr) =
          if match[2].toJs() == jsUndefined:
            (lastfile, lastLineStr, lastCharStr)
          else:
            lastFile = match[2]
            lastLineStr = match[3]
            lastCharStr = match[5]
            (match[2], match[3], match[5])

      if severity == nil:
        stacktrace.add(CheckStacktrace(
          file: file,
          line: lineStr.parseCint(),
          column: charStr.parseCint(),
          msg: msg))
      else:
        if messageText.len > 0 and result.len > 0:
          result[^1].msg &= nodeOs.eol & messageText.cstring

        messageText = ""
        result.add(CheckResult(
          file: file,
          line: lineStr.parseCint(),
          column: charStr.parseCint(),
          msg: msg,
          severity: severity,
          stacktrace: stacktrace
        ))
        stacktrace.setLen(0)
  if messageText.len > 0 and result.len > 0:
    result[^1].msg &= nodeOs.eol & messageText.cstring

proc parseNimsuggestErrors(items: seq[NimSuggestResult]): seq[CheckResult] =
  var ret: seq[CheckResult] = @[]
  for item in items.filterIt(not (it.path == "???" and it.`type` == "Hint")):
    ret.add(CheckResult{
        file: item.path,
        line: item.line,
        column: item.column,
        msg: item.documentation,
        severity: item.`type`
    })

  console.log("parseNimsuggestErrors - return", ret)
  return ret

proc check*(filename: cstring, nimConfig: VscodeWorkspaceConfiguration): Promise[
    seq[CheckResult]] =
  var runningToolsPromises: seq[Promise[seq[CheckResult]]] = @[]

  if nimConfig.getBool("useNimsuggestCheck", false):
    runningToolsPromises.add(newPromise(proc(
                resolve: proc(values: seq[CheckResult]),
                reject: proc(reason: JsObject)
            ) = execNimSuggest(NimSuggestType.chk, filename, 0, 0, false).then(
                proc(items: seq[NimSuggestResult]) =
      if items.toJs().to(bool) and items.len > 0:
        resolve(parseNimsuggestErrors(items))
      else:
        resolve(@[])
    ).catch(proc(reason: JsObject) = reject(reason))
      )
    )
  else:
    var projects = if not isProjectMode(): newArray(getProjectFileInfo(filename))
      else: getProjects()

    for project in projects:
      runningToolsPromises.add(nimExec(
          project,
          "check",
          @["--listFullPaths".cstring, project.filePath],
          true,
          parseErrors
      ))

  return all(runningToolsPromises)
    .then(proc(resultSets: seq[seq[CheckResult]]): seq[CheckResult] =
      for rs in resultSets:
        result.add(rs)
  ).catch(proc(r: JsObject): Promise[seq[CheckResult]] =
    console.error("check - all - failed", r)
    promiseReject(r).toJs().to(Promise[seq[CheckResult]])
  )

var evalTerminal: VscodeTerminal

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
