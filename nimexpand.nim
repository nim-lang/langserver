import std/[strutils]
import regex
import chronos, chronos/asyncproc
import stew/[byteutils]
import chronicles
import protocol/types
import utils
import suggestapi
import std/[strscans, strformat]


proc extractMacroExpansion*(output: string, targetLine: int): string =
  var start = false
  for line in output.split({'\n', '\r'}):
    if line.len == 0: continue
    debug "extractMacroExpansion", line = line, condMet = &".nim({targetLine}," in line
    if &".nim({targetLine}," in line:
      start = true
    elif &".nim" in line and start:
      break
    if start:
      result.add line & "\n"
    
  if result.len > 0:
    let macroStart = result.find("macro: ")
    if macroStart != -1:
      result = result.substr(macroStart + "macro: ".len)
      result = result.replace("[ExpandMacro]", "")

proc nimExpandMacro*(nimPath: string, suggest: Suggest, filePath: string): Future[string] {.async.} =
  let 
    macroName = suggest.qualifiedPath[suggest.qualifiedPath.len - 1]
    line = suggest.line
  debug "nimExpandMacro", macroName = macroName, line = line, filePath = filePath
  debug "Executing ", cmd = &"nim c --expandMacro:{macroName} {filePath}"
  let process = await startProcess(
    nimPath,
    arguments = @["c", "--expandMacro:" & macroName] & @[filePath],
    options = {UsePath, StdErrToStdOut},
    stdoutHandle = AsyncProcess.Pipe,
  )
  try:
    let res = await process.waitForExit(10.seconds)
    let output = string.fromBytes(process.stdoutStream.read().await)  
    result = extractMacroExpansion(output, line)
  finally:
    if not process.isNil: 
      discard process.kill()


proc extractArcExpansion*(output: string, procName: string): string =
  var start = false
  let cond = &"--expandArc: {procName}"
  for line in output.splitLines:
    # debug "extractArcExpansion", line = line, condMet = cond in line
    if cond in line:
      start = true
    elif &"-- end of expandArc" in line and start:
      break
    if start:
      result.add line & "\n"
  
  if result.len > 0:
    result = result.replace(cond, "").strip()


proc nimExpandArc*(nimPath: string, suggest: Suggest, filePath: string): Future[string] {.async.} =
  let procName = suggest.qualifiedPath[suggest.qualifiedPath.len - 1]
  debug "nimExpandArc", procName = procName, filePath = filePath
  let process = await startProcess(
    nimPath,
    arguments = @["c", &"--expandArc:{procName}", "--compileOnly"] & @[filePath],
    options = {UsePath, StdErrToStdOut},
    stdoutHandle = AsyncProcess.Pipe,
  )
  try:
    let res = await process.waitForExit(10.seconds)
    let output = string.fromBytes(process.stdoutStream.read().await)  
    result = extractArcExpansion(output, procName)
    # debug "nimExpandArc", output = output, result = result
    if result.len == 0:
      result = &"#Couldnt expand arc for `{procName}`. Showing raw output instead (nimPath). \n"
      result.add output      
  finally:
    if not process.isNil: 
      discard process.kill()
