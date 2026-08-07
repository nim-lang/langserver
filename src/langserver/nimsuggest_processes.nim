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

proc getWorkingDir*(ls: LanguageServer, path: string): string =
  let rootPath =
    case ls.capabilities.serverMode
    of lsp: ls.capabilities.lspInitializeParams.getRootPath
    of mcp: ls.capabilities.mcpInitializeParams.getRootPath

  let pathRelativeToRoot = path.tryRelativeTo(rootPath)
  let mapping = ls.getWorkspaceConfiguration().workingDirectoryMapping.get(@[])
  result = getCurrentDir()
  for m in mapping:
    if pathRelativeToRoot.isSome and m.projectFile == pathRelativeToRoot.get():
      result = rootPath / m.directory
      break

proc getNimbleDumpInfo*(
    ls: LanguageServer, nimbleFile: string
): Future[NimbleDumpInfo] {.async.} =
  if nimbleFile in ls.nimDumpCache:
    return ls.nimDumpCache.getOrDefault(nimbleFile)
  var process: AsyncProcessRef
  try:
    let workDir =
      if nimbleFile == "": getCurrentDir()
      else: nimbleFile.parentDir
    let nimbleDirEnv = getEnv("NIMBLE_DIR", "<not set>")
    let homeEnv = getEnv("HOME", "<not set>")
    let pathEnv = getEnv("PATH", "<not set>")
    debug "getNimbleDumpInfo environment",
      nimbleFile = nimbleFile, workDir = workDir,
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
    var nimbleFile = nimbleFile
    if nimbleFile == "":
      ls.nimDumpCache[""] = result
      if result.nimblePath.isSome:
        nimbleFile = result.nimblePath.get
    if nimbleFile != "":
      ls.nimDumpCache[nimbleFile] = result
  except CatchableError:
    debug "Failed to get nimble dump info", nimbleFile = nimbleFile
  finally:
    if process != nil:
      await shutdownChildProcess(process)

proc getNimSuggestPathAndVersion*(
  ls: LanguageServer, conf: NlsConfig, workingDir: string
): Future[(string, string)] {.async.} =
  let nimbleDumpInfo = await ls.getNimbleDumpInfo("")
  let nimDir = nimbleDumpInfo.nimDir.get ""
  var nimsuggestPath = expandTilde(conf.nimsuggestPath.get(""))
  var nimVersion = ""
  if nimsuggestPath == "":
    if nimDir != "" and nimDir.dirExists:
      nimVersion = getNimVersion(nimDir) & " from " & nimDir
      nimsuggestPath = nimDir / "nimsuggest"
    else:
      nimVersion = getNimVersion("")
      nimsuggestPath = findExe "nimsuggest"
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

proc getIntendedProject*(ls: LanguageServer, uri: string): string =
  ## ProjectMapping regex lookup only. No slot creation, no LRU fallback.
  ## Returns "" if no mapping matches.
  let path = uri.uriToPath
  let rootPath =
    case ls.capabilities.serverMode
    of lsp: ls.capabilities.lspInitializeParams.getRootPath
    of mcp: ls.capabilities.mcpInitializeParams.getRootPath
  let pathRelativeToRoot = path.tryRelativeTo(rootPath)
  let config = ls.getWorkspaceConfiguration()
  for mapping in config.projectMapping.get(@[]):
    var m: RegexMatch2
    if find(path, getCompiledRegex(mapping.fileRegex), m):
      if mapping.projectFile == "":
        return path  # regex matched but no projectFile — file is its own project
      return if isAbsolute(mapping.projectFile): mapping.projectFile
             else: rootPath / mapping.projectFile
  return ""


proc initNimsuggestInstances*(ls: LanguageServer, rootPath: string) {.async.} =
  if rootPath == "":
    return

  let config = ls.getWorkspaceConfiguration()

  # Update maxSlots from config (pool was created with defaults in initLanguageServer)
  ls.pool.maxSlots = config.maxNimsuggestProcesses.get(NIM_MAX_NS_PROCESSES)

  # Resolve the nimsuggest binary path and Nim version now that config is available.
  let (nimsuggestPath, nimVersion) = await ls.getNimSuggestPathAndVersion(config, rootPath)
  ls.pool.nimsuggestPath = nimsuggestPath
  ls.pool.nimVersion = nimVersion

  # Discover entry points via nimble dump
  let nimbleFiles = walkFiles(rootPath / "*.nimble").toSeq
  if nimbleFiles.len > 0:
    let nimbleFile = nimbleFiles[0]
    debug "Starting nimble dump for", nimbleFile = nimbleFile
    let nimbleDumpInfo = await ls.getNimbleDumpInfo(nimbleFile)
    let entryPoints = nimbleDumpInfo.getNimbleEntryPoints(rootPath)
    debug "Finished nimble dump", nimbleFile = nimbleFile

    for entryPoint in entryPoints:
      debug "Starting nimsuggest for entry point", entry = entryPoint
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
            asyncSpawn processNimsuggestQueries(slot, ls.pool, ls.files.openFiles)
          else:
            ls.pool.removeSlot(entryPoint)
        else:
          debug "Limit reached, skipping entry point", entryPoint = entryPoint
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
  let cutoff = times.now() - initDuration(milliseconds = timeout)
  for slot in ls.pool.slots.values.toSeq:
    if slot.isEntryPoint or not slot.isLive:
      continue
    if slot.lastCmdTime > cutoff:
      continue
    result.add slot


# IMPORTANT: WHat are the async functions here?  It is not clear.
proc removeIdleNimsuggests*(ls: LanguageServer) {.async.} =
  ## Kept for direct test calls — delegates to idleSlots + per-slot stop.
  ## File eviction and notification are duplicated here to keep tmisc working
  ## without a separate tick loop; langserver.nim tick() can call this too.
  for slot in ls.idleSlots():
    debug "Removing idle nimsuggest", projectFile = slot.projectFile
    ls.notify("window/showMessage", %*{
      "type": MessageType.Info.int,
      "message": fmt"Nimsuggest for {slot.projectFile} was stopped because it was idle for too long",
    })
    let successfulStop = await execStop(slot, ls.pool)
    if successfulStop:
       debug "Stopped nimsuggest"
      # slot.send SlotCommand(kind: SlotCommandKind.STOP)
    ls.pool.removeSlot(slot.projectFile)

