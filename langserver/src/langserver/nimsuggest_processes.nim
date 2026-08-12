import std/[options, tables, os, sequtils, strutils, times, strformat, json]
import chronos
import chronos/asyncproc
import stew/byteutils
import regex
import chronicles
import ../protocol/enums
import ../configurations/configuration_types
import ../nimsuggest/[nimsuggest_types, nimsuggest_slots, nimsuggest_process]
import ../nimble/[nimble, nimble_types]
import ../nim_compiler/nim_compiler
import ../utils/[process_utils]
import ../configurations/constants
import ./[langserver_types, configurations, utils]
import ../utils/utils as globalUtils
import ../protocol/types

proc getWorkingDir*(ls: LanguageServer, path: FilePath): string =
  let rootPath =
    case ls.capabilities.serverMode
    of lsp: ls.capabilities.lspInitializeParams.getRootPath
    of mcp: ls.capabilities.mcpInitializeParams.getRootPath

  let pathRelativeToRoot = string(path).tryRelativeTo(rootPath)
  let mapping = ls.getWorkspaceConfiguration().workingDirectoryMapping.get(@[])
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
  let nimbleDumpInfo = await ls.getNimbleDumpInfo(FilePath(""))
  let nimDir = nimbleDumpInfo.nimDir.get ""
  var nimsuggestPath = expandTilde(conf.nimsuggestPath.get(""))
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

var compiledRegexCache {.threadvar.}: Table[string, Regex2]

proc getCompiledRegex(pattern: string): Regex2 =
  ## Returns a cached compiled Regex2 for pattern, compiling it on first use.
  ## Chronos is single-threaded cooperative, so no locking is needed.
  if pattern notin compiledRegexCache:
    compiledRegexCache[pattern] = re2(pattern)
  compiledRegexCache[pattern]

proc clearCompiledRegexCache*() =
  ## Invalidate the regex cache. Call after workspace configuration changes so
  ## that stale projectMapping patterns are not reused across config updates.
  compiledRegexCache.clear()

proc getIntendedProject*(ls: LanguageServer, uri: FileUri): FilePath =
  ## ProjectMapping regex lookup only. No slot creation, no LRU fallback.
  ## Returns FilePath("") if no mapping matches.
  let path = uri.uriToPath
  let rootPath =
    case ls.capabilities.serverMode
    of lsp: ls.capabilities.lspInitializeParams.getRootPath
    of mcp: ls.capabilities.mcpInitializeParams.getRootPath
  let pathRelativeToRoot = string(path).tryRelativeTo(rootPath)
  let config = ls.getWorkspaceConfiguration()
  for mapping in config.projectMapping.get(@[]):
    var m: RegexMatch2
    if find(string(path), getCompiledRegex(mapping.fileRegex), m):
      if mapping.projectFile == "":
        return path  # regex matched but no projectFile — file is its own project
      return FilePath(if isAbsolute(mapping.projectFile): mapping.projectFile
                      else: rootPath / mapping.projectFile)
  return FilePath("")


proc initNimsuggestInstances*(ls: LanguageServer, rootPath: string) {.async.} =
  if rootPath == "":
    return

  let config = ls.getWorkspaceConfiguration()

  # Update pool settings from config (pool was created with defaults in initLanguageServer)
  ls.pool.maxSlots = config.maxNimsuggestProcesses.get(NIM_MAX_NS_PROCESSES)
  ls.pool.fileCheckDelay = initDuration(milliseconds = config.fileCheckDelay.get(FILE_CHECK_DELAY))

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
          let ok = await execSpawn(slot, ls.pool, entryPoint)
          if ok:
            asyncSpawn processNimsuggestQueries(
              slot, ls.pool, ls.files.openFiles, ls.notify
            )
          else:
            ls.pool.removeSlot(entryPoint)
        else:
          debug "Limit reached, skipping entry point", entryPoint = $entryPoint
          break

proc stopNimsuggestProcesses*(ls: LanguageServer) {.async.} =
  debug "stopping child nimsuggest processes"
  for slot in ls.pool.slots.values.toSeq:
    discard await execStop(slot, ls.pool)

proc stopNimsuggestProcessesP*(ls: LanguageServer) =
  waitFor ls.stopNimsuggestProcesses()

proc restartSlot*(slot: NimsuggestSlot, pool: NimsuggestPool): Future[void] {.async.} =
  ## Stop and re-spawn a single slot without removing it from the pool.
  discard await execStop(slot, pool)
  discard await execSpawn(slot, pool, slot.projectFile)

proc restartAllNimsuggestInstances*(ls: LanguageServer) =
  ## Fire-and-forget restart of every slot in the pool.
  ## Snapshots keys first to avoid mutating the table during async iteration.
  debug "Restarting all nimsuggest instances"
  for projectFile in ls.pool.slots.keys.toSeq:
    if ls.pool.slots.hasKey(projectFile):
      asyncSpawn restartSlot(ls.pool.slots[projectFile], ls.pool)

proc idleSlots*(ls: LanguageServer): seq[NimsuggestSlot] =
  ## Return slots that have exceeded the idle timeout and have no recently-active
  ## open files. The caller (langserver.nim tick) handles file eviction and
  ## notification, since it has access to files.nim procs.
  let config = ls.getWorkspaceConfiguration()
  let timeout = config.nimsuggestIdleTimeout.get(DEFAULT_IDLE_TIMEOUT)
  let cutoff = times.now() - initDuration(minutes = timeout)
  for slot in ls.pool.slots.values.toSeq:
    # if slot.isEntryPoint or not slot.isLive:
    if slot.isLive == false:
      continue
    if slot.lastCmdTime > cutoff:
      continue
    result.add(slot)

# proc removeIdleNimsuggests*(ls: LanguageServer) {.async.} =
#   ## Kept for direct test calls — delegates to idleSlots + per-slot stop.
#   ## File eviction and notification are duplicated here to keep tmisc working
#   ## without a separate tick loop; langserver.nim tick() can call this too.
#   for slot in ls.idleSlots():
#     debug "Removing idle nimsuggest", projectFile = slot.projectFile
#     ls.notify("window/showMessage", %*{
#       "type": MessageType.Info.int,
#       "message": fmt"Nimsuggest for {slot.projectFile} was stopped because it was idle for too long",
#     })
#     let successfulStop = await execStop(slot, ls.pool)
#     if successfulStop:
#        debug "Stopped nimsuggest"
#       # slot.send SlotCommand(kind: SlotCommandKind.STOP)
#     ls.pool.removeSlot(slot.projectFile)

