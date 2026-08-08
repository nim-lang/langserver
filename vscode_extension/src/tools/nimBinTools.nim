# Track down the various nim tools: `nim`, `nimble`, `nimsuggest`, ...

import platform/js/[jsNode, jsNodePath, jsString, jsNodeFs, jsNodeCp]

import std/jsffi
from std/sequtils import mapIt, foldl, filterIt, concat
import ../[spec, nimUtils]
var binPathsCache = newMap[cstring, cstring]()

proc getBinPath*(tool: cstring, initialSearchPaths: openArray[cstring] = []): cstring =
  if binPathsCache[tool].toJs().to(bool):
    return binPathsCache[tool]
  if not process.env["PATH"].isNil():
    # USERPROFILE is the standard equivalent of HOME on windows.
    let userHomeVarName = if process.platform == "win32": "USERPROFILE" else: "HOME"

    # add support for choosenim
    let fullEnvPath =
      path.join(process.env[userHomeVarName], ".nimble", "bin") & path.delimiter &
      process.env["PATH"]

    let pathParts: seq[cstring] =
      concat(@initialSearchPaths, fullEnvPath.split(path.delimiter))

    let endings =
      if process.platform == "win32":
        @[".exe", ".cmd", ""]
      else:
        @[""]

    let paths = pathParts
      .mapIt(
        block:
          var dir = it
          endings.mapIt(path.join(dir, tool & cstring(it)))
      )
      .foldl(a & b)
      # flatten nested arays
      .filterIt(fs.existsSync(it))

    if paths.len == 0:
      return nil

    binPathsCache[tool] = paths[0]
    if process.platform != "win32":
      try:
        var nimPath: cstring
        case $(process.platform)
        of "darwin":
          nimPath =
            cp.execFileSync("readlink", @[binPathsCache[tool]]).toString().strip()
          if nimPath.len > 0 and not path.isAbsolute(nimPath):
            nimPath =
              path.normalize(path.join(path.dirname(binPathsCache[tool]), nimPath))
        of "linux":
          nimPath = cp
            .execFileSync("readlink", @[cstring("-f"), binPathsCache[tool]])
            .toString()
            .strip()
        else:
          nimPath =
            cp.execFileSync("readlink", @[binPathsCache[tool]]).toString().strip()

        if nimPath.len > 0:
          binPathsCache[tool] = nimPath
      except:
        discard #ignore
  binPathsCache[tool]

proc getNimExecPath*(executable: cstring = "nim"): cstring =
  ## returns the path to the an executable by name, defaults to nim, returns an
  ## empty string in case it wasn't found.
  var initialPaths = newSeq[cstring]()

  if executable == "nim" and ext.nimDir != "":
    # use the nimDir from nimble as the initial search path when it's set.
    initialPaths.add(ext.nimDir.cstring)

  result = getBinPath(executable, initialPaths)
  if result.isNil():
    result = ""

proc getOptionalToolPath(tool: cstring): cstring =
  if not binPathsCache.has(tool):
    let execPath = path.resolve(getBinPath(tool))
    if fs.existsSync(execPath):
      binPathsCache[tool] = execPath
    else:
      binPathsCache[tool] = ""
  return binPathsCache[tool]

proc getNimPrettyExecPath*(): cstring =
  ## full path to nimpretty executable or an empty string if not found
  return getOptionalToolPath("nimpretty")

proc getNimbleExecPath*(): cstring =
  ## full path to nimble executable or an empty string if not found
  return getOptionalToolPath("nimble")


proc execNimbleCmd*(args: seq[cstring], dirPath: cstring, onCloseCb: proc(code: cint, signal: cstring): void {.closure.}) = 
    var process = cp.spawn(
      getNimbleExecPath(), @["setup".cstring], SpawnOptions(shell: true, cwd: dirPath)
    )
    process.stdout.onData(
      proc(data: Buffer) =
        outputLine(data.toString())
    )
    process.stderr.onData(
      proc(data: Buffer) =
        let msg = $data.toString()
        if msg.contains("Warning: "):
          outputLine(("[Warning]" & msg).cstring)
        else:
          outputLine(("[Error]" & msg).cstring)
    )
    process.onClose(onCloseCb)