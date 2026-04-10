import
  strformat,
  chronos,
  chronos/asyncproc,
  json_rpc/server,
  os,
  sugar,
  sequtils,
  suggestapi,
  protocol/enums,
  protocol/types,
  with,
  tables,
  chronicles,
  asyncprocmonitor,
  json_serialization,
  std/[strscans, times, json, parseutils, strutils],
  regex,
  stew/[byteutils],
  nimexpand,
  testrunner,
  ../[ls, utils]

import macros except error

proc logToFile(msg: string) =
  var logFile = open("mcp.log", fmAppend)
  logFile.writeLine(msg)
  close(logFile)

#routes
proc initialize*(
    p: tuple[ls: LanguageServer, onExit: OnExitCallback], params: McpInitializeParams
): Future[McpInitializeResult] {.async.} =
  logToFile("============================")
  logToFile("--== Started initialize ==--")

  proc onClientProcessExitAsync(): Future[void] {.async.} =
    debug "onClientProcessExitAsync"
    await p.ls.stopNimsuggestProcesses
    await p.onExit()

  proc onClientProcessExit() {.closure, gcsafe.} =
    try:
      debug "onClientProcessExit"
      waitFor onClientProcessExitAsync()
    except Exception:
      error "Error in onClientProcessExit ", msg = getCurrentExceptionMsg()

  debug "Initialize received..."
  logToFile "Initialize received..."
  p.ls.mcpInitializeParams = params
  p.ls.mcpClientCapabilities = params.capabilities
  result = McpInitializeResult(
    protocolVersion: "2025-11-25",
    capabilities: McpServerCapabilities(tools: some(McpToolsOptions())),
    serverInfo: McpInitializeParams_serverInfo(name: "nimlangserver", version: "1.12.0"),
  )

  debug "Initialize completed. Trying to start nimsuggest instances"
  logToFile "Initialize completed. Trying to start nimsuggest instances"
  let ls = p.ls
  ls.mcpServerCapabilities = result.capabilities
  let rootPath = getCurrentDir().pathToUri.uriToPath
  logToFile "rootPath = " & $rootPath
  if rootPath != "":
    let nimbleFiles = walkFiles(rootPath / "*.nimble").toSeq
    logToFile "nimbleFiles = " & $nimbleFiles
    if nimbleFiles.len > 0:
      let nimbleFile = nimbleFiles[0]
      let nimbleDumpInfo = await ls.getNimbleDumpInfo(nimbleFile)
      logToFile "nimbleDumpInfo = " & $nimbleDumpInfo
      ls.entryPoints = nimbleDumpInfo.getNimbleEntryPoints(rootPath)
      logToFile "ls.entryPoints = " & $ls.entryPoints
      for entryPoint in ls.entryPoints:
        debug "Starting nimsuggest for entry point ", entry = entryPoint
        logToFile "Starting nimsuggest for entry point " & entryPoint
        if entryPoint notin ls.projectFiles:
          ls.createOrRestartNimsuggest(entryPoint)
