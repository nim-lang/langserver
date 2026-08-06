import std/[options, tables, algorithm, os, sequtils, sugar]
import chronos
import chronicles
import ../protocol/[enums, types]

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
    if find(path, re2(mapping.fileRegex), m):
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
          slot.state = SlotState.SPAWNING # Reserve liveCount immediately
          ls.pool.addSlot(slot)
          # asyncSpawn processCommands(slot, ls.pool)
          asyncSpawn processNimsuggestQueries(slot, ls.pool)
          # slot.send SlotCommand(
          #   kind: SlotCommandKind.SPAWN,
          #   spawnProjectFile: entryPoint,
          #   spawnTriggerUri: entryPoint.pathToUri,
          # )
        else:
          debug "Limit reached, skipping entry point", entryPoint = entryPoint
          break

# proc stopNimsuggestProcesses*(ls: LanguageServer) {.async.} =
#   debug "stopping child nimsuggest processes"
#   for slot in ls.pool.slots.values:
#     slot.send SlotCommand(kind: SlotCommandKind.STOP)
#   await sleepAsync(500)
#   # WHat is the point of this sleepAsync here - shouldn't this be happening when the slot processes the SlotCOmmand?

# proc stopNimsuggestProcessesP*(ls: LanguageServer) =
#   waitFor stopNimsuggestProcesses(ls)

# proc restartAllNimsuggestInstances*(ls: LanguageServer) =
#   debug "Restarting all nimsuggest instances"
#   for projectFile, slot in ls.pool.slots.pairs:
#     slot.send SlotCommand(
#       kind: SlotCommandKind.RESTART,
#       spawnProjectFile: projectFile,
#       spawnTriggerUri: projectFile.pathToUri,
#     )

proc idleSlots*(ls: LanguageServer): seq[NimsuggestSlot] =
  ## Return slots that have exceeded the idle timeout and have no recently-active
  ## open files. The caller (langserver.nim tick) handles file eviction and
  ## notification, since it has access to files.nim procs.
  let config = ls.getWorkspaceConfiguration()
  let timeout = config.nimsuggestIdleTimeout.get(DEFAULT_IDLE_TIMEOUT)
  let cutoff = now() - initDuration(milliseconds = timeout)
  for slot in ls.pool.slots.values.toSeq:
    if slot.isEntryPoint or not slot.isLive:
      continue
    if slot.lastCmdTime.isSome and slot.lastCmdTime.get > cutoff:
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
    slot.send SlotCommand(kind: SlotCommandKind.STOP)
    ls.pool.removeSlot(slot.projectFile)

