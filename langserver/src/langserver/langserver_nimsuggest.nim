import std/[options, tables, os, sequtils, strutils, times, strformat, json]
import chronos
import chronos/asyncproc
import stew/byteutils
import regex
import chronicles

import ../protocol/enums
import ../nimble/[nimble, nimble_types]
import ../nim_compiler/nim_compiler
import ../configurations/configurations
import ../nimsuggest/nimsuggest
import ../utils/[process_utils]
import ../utils/utils
import ./[langserver_types, langserver_utils]
import ../protocol/types

proc getWorkingDir*(ls: LanguageServer, path: FilePath): string =
  let rootPath =
    case ls.capabilities.serverMode
    of lsp: ls.capabilities.lspInitializeParams.getRootPath
    of mcp: ls.capabilities.mcpInitializeParams.getRootPath

  let pathRelativeToRoot = string(path).tryRelativeTo(rootPath)
  let mapping = ls.configurations.currentConfig.workingDirectoryMapping
  result = getCurrentDir()
  for m in mapping:
    if pathRelativeToRoot.isSome and m.projectFile == pathRelativeToRoot.get():
      result = rootPath / m.directory
      break


proc getNimbleDumpInfo*(
    ls: LanguageServer, nimbleFile: FilePath
): Future[NimbleDumpInfo] {.async.} =
  if string(nimbleFile) in ls.nimDumpCache:
    return ls.nimDumpCache.getOrDefault(string(nimbleFile))
  var process: AsyncProcessRef
  try:
    let workDir =
      if string(nimbleFile) == "": getCurrentDir()
      else: string(nimbleFile).parentDir
    let nimbleDirEnv = getEnv("NIMBLE_DIR", "<not set>")
    let homeEnv = getEnv("HOME", "<not set>")
    let pathEnv = getEnv("PATH", "<not set>")
    debug "getNimbleDumpInfo environment",
      nimbleFile = $nimbleFile, workDir = workDir,
      NIMBLE_DIR = nimbleDirEnv, HOME = homeEnv, PATH = pathEnv
    process = await startProcess(
      "nimble",
      workingDir = workDir,
      arguments = @["dump"],
      options = {UsePath},
      stderrHandle = AsyncProcess.Pipe,
      stdoutHandle = AsyncProcess.Pipe,
    )
    let info = string.fromBytes(process.stdoutStream.read().await)
    debug "getNimbleDumpInfo result ", info
    for line in info.splitLines:
      if line.startsWith("srcDir"):
        result.srcDir = line[(1 + line.find '"') ..^ 2]
      if line.startsWith("name"):
        result.name = line[(1 + line.find '"') ..^ 2]
      if line.startsWith("nimDir"):
        result.nimDir = some line[(1 + line.find '"') ..^ 2]
      if line.startsWith("nimblePath"):
        result.nimblePath = some line[(1 + line.find '"') ..^ 2]
      if line.startsWith("entryPoints"):
        result.entryPoints =
          line[(1 + line.find '"') ..^ 2].split(',').mapIt(it.strip(chars = {' ', '"'}))
    var nimbleFileStr = string(nimbleFile)
    if nimbleFileStr == "":
      ls.nimDumpCache[""] = result
      if result.nimblePath.isSome:
        nimbleFileStr = result.nimblePath.get
    if nimbleFileStr != "":
      ls.nimDumpCache[nimbleFileStr] = result
  except CatchableError:
    debug "Failed to get nimble dump info", nimbleFile = $nimbleFile
  finally:
    if process != nil:
      await shutdownChildProcess(process)

proc getNimSuggestPathAndVersion*(
  ls: LanguageServer, conf: NlsConfig, workingDir: string
): Future[(string, string)] {.async.} =
  let nimbleDumpInfo = await getNimbleDumpInfo(ls, FilePath(""))
  let nimDir = nimbleDumpInfo.nimDir.get ""
  var nimsuggestPath = expandTilde(conf.nimsuggestPath)
  var nimVersion = ""
  if nimsuggestPath == "":
    if nimDir != "" and nimDir.dirExists:
      nimVersion = getNimVersion(nimDir) & " from " & nimDir
      nimsuggestPath = nimDir / "nimsuggest".addFileExt(ExeExt)
    else:
      nimVersion = getNimVersion("")
      nimsuggestPath = findExe "nimsuggest"
      # Fallback for restricted PATH environments (e.g. Dock launch on macOS where
      # PATH is /usr/bin:/bin:/usr/sbin:/sbin and ~/.nimble/bin is not included,
      # or Linux desktop launches that only source ~/.profile). Uses ExeExt so
      # the check works on Windows ("nimsuggest.exe") too.
      if nimsuggestPath == "":
        let nimbleBinPath = getHomeDir() / ".nimble" / "bin" / "nimsuggest".addFileExt(ExeExt)
        if fileExists(nimbleBinPath):
          nimsuggestPath = nimbleBinPath
  else:
    nimVersion = getNimVersion(nimsuggestPath.parentDir)
  debug "Using nimsuggest", nimVersion = nimVersion, path = nimsuggestPath
  (nimsuggestPath, nimVersion)

proc initNimsuggestInstances*(ls: LanguageServer, rootPath: string) {.async.} =
  if rootPath == "":
    return

  let config = ls.configurations.currentConfig

  # Update pool settings from config (pool was created with defaults in initLanguageServer)
  ls.pool.maxSlots = config.maxNimsuggestProcesses
  ls.pool.fileCheckDelay = initDuration(milliseconds = config.fileCheckDelay)

  # Resolve the nimsuggest binary path and Nim version now that config is available.
  let (nimsuggestPath, nimVersion) = await ls.getNimSuggestPathAndVersion(config, rootPath)
  ls.pool.nimsuggestPath = nimsuggestPath
  ls.pool.nimVersion = nimVersion

  # Discover entry points via nimble dump
  let nimbleFiles = walkFiles(rootPath / "*.nimble").toSeq
  if nimbleFiles.len > 0:
    let nimbleFile = FilePath(nimbleFiles[0])
    debug "Starting nimble dump for", nimbleFile = $nimbleFile
    let nimbleDumpInfo = await ls.getNimbleDumpInfo(nimbleFile)
    let entryPoints = nimbleDumpInfo.getNimbleEntryPoints(rootPath).mapIt(FilePath(it))
    debug "Finished nimble dump", nimbleFile = $nimbleFile

    for entryPoint in entryPoints:
      debug "Starting nimsuggest for entry point", entry = $entryPoint
      if entryPoint notin ls.pool.slots:
        if ls.pool.canSpawn:
          let slot = newSlot(entryPoint, isEntryPoint = true)
          ls.pool.addSlot(slot)
          # Await the spawn so the slot is live before processing the next
          # entry point. initNimsuggestInstances is called via asyncSpawn from
          # the initialized handler, so awaiting here does not block the LSP
          # event loop — Chronos continues serving other messages while waiting.
          let ok = await execSpawn(slot, ls.pool, entryPoint, ls.configurations.currentConfig)
          if ok:
            asyncSpawn processNimsuggestQueries(
              slot, ls.pool, ls.files.openFiles, 
              ls.configurations.currentConfig,
              ls.notify
            )
          else:
            ls.pool.removeSlot(entryPoint)
        else:
          debug "Limit reached, skipping entry point", entryPoint = $entryPoint
          break

