import std/[os, sequtils, options, strformat, strutils, times, sets, tables, json]

import chronos
import chronicles
import regex

import ./[suggestapi, nimsuggest_types]
import ../protocol/[types, enums]
import ../langserver/[langserver_types, configuration_types, configurations, utils, constants, queue_types, queues, diagnostics, messaging_types]
import ../nimble/nimble
import ../nim_compiler/nim_compiler


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
      return rootPath / mapping.projectFile
  return ""

proc makeSpawnProc*(ls: LanguageServer): SpawnProc =
  ## Returns a SpawnProc closure that creates a nimsuggest process.
  result = proc(
      projectFile: string, nimPaths: seq[string]
  ): Future[NimSuggest] {.gcsafe, raises: [].} =
    let fut = newFuture[NimSuggest]("makeSpawnProc")
    proc doSpawn() {.async.} =
      try:
        let conf = ls.getWorkspaceConfiguration()
        let workingDir = ls.getWorkingDir(projectFile)
        let (nimsuggestPath, version) =
          await ls.getNimSuggestPathAndVersion(conf, workingDir)
        let timeout = conf.timeout.get(REQUEST_TIMEOUT)
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
          nimPaths & findNimblePaths(projectFile),
        )
        if projectResult.ns.finished and not projectResult.ns.failed:
          let nsInitMsg = newJObject()
          nsInitMsg["type"] = newJInt(MessageType.Info.int)
          nsInitMsg["message"] = newJString(fmt "Nimsuggest initialized for {projectFile}")
          ls.notify("window/showMessage", nsInitMsg)
          fut.complete(projectResult.ns.read())
        else:
          fut.fail(newException(CatchableError, "Nimsuggest startup failed"))
      except CatchableError as ex:
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
      let projectFile = rootPath / mapping.projectFile
      if projectFile in ls.pool.slots:
        return ls.pool.slots[projectFile]
      # Slot doesn't exist yet — only create it if we have capacity.
      # If at the limit, return the LRU slot; CHECK_KNOWN will route the
      # URI to the right place via EVICT_AND_SPAWN once nimsuggest replies.
      if ls.pool.canSpawn:
        let slot = newSlot(projectFile)
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

proc removeIdleNimsuggests*(ls: LanguageServer) {.async.} =
  let config = ls.getWorkspaceConfiguration()
  let timeout = config.nimsuggestIdleTimeout.get(DEFAULT_IDLE_TIMEOUT)
  let cutoff = now() - initDuration(minutes = timeout)
  # Snapshot values before iterating: removeSlot mutates the table.
  for slot in ls.pool.slots.values.toSeq:
    if slot.isEntryPoint or not slot.isLive:
      continue
    if slot.lastCmdTime.isSome and slot.lastCmdTime.get > cutoff:
      continue
    if slot.ownedUris.len == 0:
      debug "Removing idle nimsuggest", projectFile = slot.projectFile
      slot.send SlotCommand(kind: SlotCommandKind.STOP)
      ls.pool.removeSlot(slot.projectFile) # slot object lives on in its coroutines

