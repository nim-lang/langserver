import std/[os, options, json, sequtils, strutils]
import chronos
import chronos/asyncproc
import chronicles
import stew/byteutils

import ../protocol/types
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
