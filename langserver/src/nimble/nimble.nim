import std/[os, sequtils, strutils]
import chronos
import chronicles

import ./nimble_types

proc getNimbleEntryPoints*(
    dumpInfo: NimbleDumpInfo, nimbleProjectPath: string
): seq[string] =
  if dumpInfo.entryPoints.len > 0:
    result = dumpInfo.entryPoints.mapIt(nimbleProjectPath / it)
  else:
    #Nimble doesnt include the entry points, returning the nimble project file as the entry point
    let sourceDir = nimbleProjectPath / dumpInfo.srcDir
    result = @[sourceDir / (dumpInfo.name & ".nim")]
  result = result.filterIt(it.fileExists)

proc findNimblePaths*(fromFile: string): seq[string] =
  ## Walk up from fromFile's directory looking for nimble.paths.
  ## Returns the flags it contains (--noNimblePath and --path:... entries)
  ## with any surrounding quotes stripped, ready to pass directly to nimsuggest.
  var dir = fromFile.parentDir
  while dir.len > 0:
    let pathsFile = dir / "nimble.paths"
    if pathsFile.fileExists:
      debug "Found nimble.paths for nimsuggest", path = pathsFile
      for line in pathsFile.lines:
        let trimmed = line.strip()
        if trimmed.len == 0:
          continue
        if trimmed.startsWith("--path:"):
          # nimble.paths wraps paths in quotes: --path:"/foo/bar"
          # Strip them so the arg is passed cleanly to nimsuggest.
          let val = trimmed[7 .. ^1]
          if val.len >= 2 and val[0] == '"' and val[^1] == '"':
            result.add("--path:" & val[1 .. ^2])
          else:
            result.add(trimmed)
        else:
          result.add(trimmed)
      return
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent

# proc getNimbleDumpInfo*(
#   nimDumpCache: ref Table[string, NimbleDumpInfo],
#   nimbleFile: FilePath
# ): Future[NimbleDumpInfo] {.async.} =
#   if string(nimbleFile) in nimDumpCache:
#     return nimDumpCache.getOrDefault(string(nimbleFile))
#   var process: AsyncProcessRef
#   try:
#     let workDir =
#       if string(nimbleFile) == "": getCurrentDir()
#       else: string(nimbleFile).parentDir
#     let nimbleDirEnv = getEnv("NIMBLE_DIR", "<not set>")
#     let homeEnv = getEnv("HOME", "<not set>")
#     let pathEnv = getEnv("PATH", "<not set>")
#     debug "getNimbleDumpInfo environment",
#       nimbleFile = $nimbleFile, workDir = workDir,
#       NIMBLE_DIR = nimbleDirEnv, HOME = homeEnv, PATH = pathEnv
#     process = await startProcess(
#       "nimble",
#       workingDir = workDir,
#       arguments = @["dump"],
#       options = {UsePath},
#       stderrHandle = AsyncProcess.Pipe,
#       stdoutHandle = AsyncProcess.Pipe,
#     )
#     let info = string.fromBytes(process.stdoutStream.read().await)
#     debug "getNimbleDumpInfo result ", info
#     for line in info.splitLines:
#       if line.startsWith("srcDir"):
#         result.srcDir = line[(1 + line.find '"') ..^ 2]
#       if line.startsWith("name"):
#         result.name = line[(1 + line.find '"') ..^ 2]
#       if line.startsWith("nimDir"):
#         result.nimDir = some line[(1 + line.find '"') ..^ 2]
#       if line.startsWith("nimblePath"):
#         result.nimblePath = some line[(1 + line.find '"') ..^ 2]
#       if line.startsWith("entryPoints"):
#         result.entryPoints =
#           line[(1 + line.find '"') ..^ 2].split(',').mapIt(it.strip(chars = {' ', '"'}))
#     var nimbleFileStr = string(nimbleFile)
#     if nimbleFileStr == "":
#       nimDumpCache[""] = result
#       if result.nimblePath.isSome:
#         nimbleFileStr = result.nimblePath.get
#     if nimbleFileStr != "":
#       nimDumpCache[nimbleFileStr] = result
#   except CatchableError:
#     debug "Failed to get nimble dump info", nimbleFile = $nimbleFile
#   finally:
#     if process != nil:
#       await shutdownChildProcess(process)
