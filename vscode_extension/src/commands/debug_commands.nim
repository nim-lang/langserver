
import platform/vscodeApi
import platform/js/[jsNodePath, jsNodeCp]
import std/[strformat, strutils]
from ../tools/nimBinTools import getNimbleExecPath
import ../tools/nimUtils
import ../state/state_types

type
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

proc onStartDebugSession*(session: VscodeDebugSession) =
  ## load the nimprettylldb.py script into the debugger
  let dirname {.importjs: "__dirname".}: cstring
  let pyScriptPath = path.join(dirname, "../scripts/nimprettylldb.py")
  let cmd = cstring(&"command script import {pyScriptPath}")
  let arg = VscodeDebugExpression(expression: cmd, context: "repl")
  discard session.customRequest("evaluate", arg)

proc setNimDir*(state: ExtensionState) =
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