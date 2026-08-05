import std/[os, sequtils, options, strformat, strutils, times, sets, tables, json]

import chronos
import chronicles
import regex

import ./[suggestapi, nimsuggest_types]
import ../../protocol/[types, enums]
import ../../langserver/[langserver_types, configuration_types, configurations, utils, constants, queue_types, queues, diagnostics, messaging_types]
import ../nimble/nimble
import ../compiler/nim_compiler


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

proc makeSpawnProc*(ls: LanguageServer): SpawnProc =
  ## Returns a SpawnProc closure that creates a nimsuggest process.
  result = proc(
      projectFile: string, nimPaths: seq[string]
  ): Future[NimSuggest] {.gcsafe, raises: [].} =
    let fut = newFuture[NimSuggest]("makeSpawnProc")
    debug "makeSpawnProc: scheduling doSpawn", projectFile = projectFile
    proc doSpawn() {.async.} =
      debug "makeSpawnProc.doSpawn: enter", projectFile = projectFile
      try:
        let conf = ls.getWorkspaceConfiguration()
        let workingDir = ls.getWorkingDir(projectFile)
        debug "makeSpawnProc.doSpawn: resolving nimsuggest path",
          projectFile = projectFile, workingDir = workingDir
        let (nimsuggestPath, version) =
          await ls.getNimSuggestPathAndVersion(conf, workingDir)
        debug "makeSpawnProc.doSpawn: nimsuggest path resolved",
          projectFile = projectFile, nimsuggestPath = nimsuggestPath
        let timeout = conf.timeout.get(REQUEST_TIMEOUT)
        let nimPathFlags = nimPaths & findNimblePaths(projectFile)
        debug "makeSpawnProc.doSpawn: calling createNimsuggest",
          projectFile = projectFile, nimPathCount = nimPathFlags.len
        let projectResult = await createNimsuggest(
          projectFile,
          nimsuggestPath,
          version,
          timeout,
          proc(ns: NimSuggest) {.gcsafe, raises: [].} = discard,
          proc(pr: Project) {.gcsafe, raises: [].} = discard,
          workingDir,
          conf.logNimsuggest.get(false),
          conf.exceptionHintsEnabled,
          nimPathFlags,
        )
        debug "makeSpawnProc.doSpawn: createNimsuggest returned",
          projectFile = projectFile,
          nsFinished = projectResult.ns.finished,
          nsFailed = projectResult.ns.failed
        if projectResult.ns.finished and not projectResult.ns.failed:
          let nsInitMsg = newJObject()
          nsInitMsg["type"] = newJInt(MessageType.Info.int)
          nsInitMsg["message"] = newJString(fmt "Nimsuggest initialized for {projectFile}")
          debug "makeSpawnProc.doSpawn: sending initialized notification",
            projectFile = projectFile
          ls.notify("window/showMessage", nsInitMsg)
          fut.complete(projectResult.ns.read())
        else:
          debug "makeSpawnProc.doSpawn: ns future failed or not finished, failing fut",
            projectFile = projectFile,
            nsFinished = projectResult.ns.finished,
            nsFailed = projectResult.ns.failed
          fut.fail(newException(CatchableError, "Nimsuggest startup failed"))
      except CatchableError as ex:
        debug "makeSpawnProc.doSpawn: caught exception",
          projectFile = projectFile, msg = ex.msg
        if not fut.finished:
          fut.fail(ex)
    asyncSpawn doSpawn()
    fut

proc makeStopProc*(): StopProc =
  result = proc(ns: NimSuggest): Future[void] {.gcsafe, raises: [].} =
    let fut = newFuture[void]("makeStopProc")
    proc doStop() {.async.} =
      try:
        if ns != nil and ns.project != nil and ns.project.process != nil:
          await shutdownChildProcess(ns.project.process)
      except CatchableError:
        discard
      if not fut.finished:
        fut.complete()
    asyncSpawn doStop()
    fut

proc makeIsKnownProc*(): IsKnownProc =
  result = proc(
      ns: NimSuggest, filePath: string
  ): Future[bool] {.gcsafe, raises: [].} =
    ns.isKnown(filePath)

# IMPORTANT: SHould this fucntion be async?  It has asyncSpawn inside it?

proc getOrCreateSlotForUri*(ls: LanguageServer, uri: string): NimsuggestSlot =
  ## Synchronously find or create the slot for this URI.
  ## 1. Check if already assigned via ownedUris scan.
  ## 2. Try projectMapping regex lookup.
  ## 3. Fall back to LRU slot (or spawn new if canSpawn).
  # Check if already assigned
  let existingOpt = ls.pool.slotForUri(uri)
  if existingOpt.isSome:
    return existingOpt.get

  let path = uri.uriToPath
  let rootPath =
    case ls.capabilities.serverMode
    of lsp: ls.capabilities.lspInitializeParams.getRootPath
    of mcp: ls.capabilities.mcpInitializeParams.getRootPath
  let pathRelativeToRoot = path.tryRelativeTo(rootPath)
  let config = ls.getWorkspaceConfiguration()

  # Check projectMapping regexes
  for mapping in config.projectMapping.get(@[]):
    var m: RegexMatch2
    if find(path, re2(mapping.fileRegex), m):
      let projectFile =
        if mapping.projectFile == "": path
        elif isAbsolute(mapping.projectFile): mapping.projectFile
        else: rootPath / mapping.projectFile
      if projectFile in ls.pool.slots:
        return ls.pool.slots[projectFile]
      # Slot doesn't exist yet — only create it if we have capacity.
      # If at the limit, return the LRU slot; CHECK_KNOWN will route the
      # URI to the right place via EVICT_AND_SPAWN once nimsuggest replies.
      if ls.pool.canSpawn:
        let slot = newSlot(projectFile)
        slot.state = SlotState.SPAWNING # Reserve liveCount so concurrent opens see capacity used
        ls.pool.addSlot(slot)
        asyncSpawn processCommands(slot, ls.pool)
        asyncSpawn processQueries(slot, ls.pool)
        return slot
      else:
        let lruOpt = ls.pool.lruSlot
        if lruOpt.isSome:
          return lruOpt.get
        for slot in ls.pool.slots.values:
          return slot

  # No mapping match — use LRU or spawn new
  if ls.pool.canSpawn:
    let slot = newSlot(path)
    slot.state = SlotState.SPAWNING # Reserve liveCount so concurrent opens see capacity used
    ls.pool.addSlot(slot)
    asyncSpawn processCommands(slot, ls.pool)
    asyncSpawn processQueries(slot, ls.pool)
    return slot
  else:
    let lruOpt = ls.pool.lruSlot
    if lruOpt.isSome:
      return lruOpt.get
    # Fallback: return the first slot if any exist
    for slot in ls.pool.slots.values:
      return slot
    # If pool is empty, create a slot anyway
    let slot = newSlot(path)
    slot.state = SlotState.SPAWNING # Reserve liveCount so concurrent opens see capacity used
    ls.pool.addSlot(slot)
    asyncSpawn processCommands(slot, ls.pool)
    asyncSpawn processQueries(slot, ls.pool)
    return slot

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
          asyncSpawn processCommands(slot, ls.pool)
          asyncSpawn processQueries(slot, ls.pool)
          slot.send SlotCommand(
            kind: SlotCommandKind.SPAWN,
            spawnProjectFile: entryPoint,
            spawnTriggerUri: entryPoint.pathToUri,
          )
        else:
          debug "Limit reached, skipping entry point", entryPoint = entryPoint
          break

proc stopNimsuggestProcesses*(ls: LanguageServer) {.async.} =
  debug "stopping child nimsuggest processes"
  for slot in ls.pool.slots.values:
    slot.send SlotCommand(kind: SlotCommandKind.STOP)
  await sleepAsync(500)
  # WHat is the point of this sleepAsync here - shouldn't this be happening when the slot processes the SlotCOmmand?

proc stopNimsuggestProcessesP*(ls: LanguageServer) =
  waitFor stopNimsuggestProcesses(ls)

proc restartAllNimsuggestInstances*(ls: LanguageServer) =
  debug "Restarting all nimsuggest instances"
  for projectFile, slot in ls.pool.slots.pairs:
    slot.send SlotCommand(
      kind: SlotCommandKind.RESTART,
      spawnProjectFile: projectFile,
      spawnTriggerUri: projectFile.pathToUri,
    )

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

