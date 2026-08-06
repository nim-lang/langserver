import std/[options, tables, algorithm, os, sequtils, sugar]
import chronos
import chronicles
import ../nim_tools/nimsuggest/[suggestapi, nimsuggest_types, nimsuggest]
import ../nim_tools/nimcheck/nimcheck
import ../nim_tools/compiler/nim_compiler
import ../protocol/[enums, types]
import ./[
  checking, configurations,
  constants, diagnostics, formatting, 
  dispatcher_utils
]
import ./[langserver_types, nimsuggest_types, query_types]

# === UTILS ===
proc isLive*(slot: NimsuggestSlot): bool =
  slot.state == SlotState.READY

proc isActive*(slot: NimsuggestSlot): bool =
  ## Live or currently starting up. Counts against maxSlots.
  slot.state in {SlotState.SPAWNING, SlotState.READY}

proc ownsUri*(slot: NimsuggestSlot, uri: string): bool =
  uri in slot.ownedUris

proc resolvedNs*(slot: NimsuggestSlot): Option[NimSuggest] =
  ## Returns the live NimSuggest if the slot is ready, else none.
  if slot.ns.isSome:
    let fut = slot.ns.get
    if fut.finished and not fut.failed:
      return some(fut.read)
  none(NimSuggest)

# === PROCESSING === 
proc runNimsuggestQuery*(
  ns: Nimsuggest, 
  q: NimsuggestQuery
): Future[seq[Suggest]] {.async.} =
  let path = q.uri.uriToPath
  case q.kind
  of NimsuggestQueryKind.SUGGEST:
    return await ns.sug(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.DEFINITION:
    return await ns.def(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.DECLARATION:
    return await ns.declaration(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.TYPE_DEFINITION:
    return await ns.type(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.REFERENCES:
    return await ns.use(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.HOVER, NimsuggestQueryKind.DOCUMENT_HIGHLIGHT:
    return await ns.highlight(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.SIGNATURE_HELP:
    return await ns.con(path, q.dirtyFile, q.position.line, q.position.col)
  of NimsuggestQueryKind.DOCUMENT_SYMBOLS:
    return await ns.outline(path, q.dirtyFile)
  of NimsuggestQueryKind.WORKSPACE_SYMBOLS:
    return await ns.globalSymbols(path, q.dirtyFile)
  of NimsuggestQueryKind.INLAY_HINTS:
    return await ns.inlayHints(
      path, q.dirtyFile,
      q.inlayHints.start.line, q.inlayHints.start.col,
      q.inlayHints.finish.line, q.inlayHints.finish.col,
      q.inlayHints.options
    )
  of NimsuggestQueryKind.EXPAND:
    return await ns.expand(
      path, 
      q.dirtyFile, 
      q.expand.position.line, q.expand.position.col, 
      q.expand.tag
    )
  of NimsuggestQueryKind.CHANGED:
    return await ns.changed(path, q.dirtyFile)
  of NimsuggestQueryKind.CHECK_FILE:
    return await ns.chkFile(path, q.dirtyFile)
  of NimsuggestQueryKind.CHECK_PROJECT:
    return await ns.chk(path, q.dirtyFile)
  of NimsuggestQueryKind.RECOMPILE:
    return await ns.recompile()
  of NimsuggestQueryKind.KNOWN:
    return await ns.known(path)


proc processNimsuggestQueries*(slot: NimsuggestSlot, pool: NimsuggestPool) {.async.} =
  debug "processQueries: starting", projectFile = slot.projectFile
  while true:
    let q = await slot.queryMailbox.popFirst()

    # Wait until the slot has a live process.
    # If the slot is stopped/crashed, we still drain the queue so callers
    # get @[] rather than hanging forever.
    if slot.ns.isSome:
      try:
        discard await slot.ns.get # waits for SPAWNING → READY
      except CatchableError:
        # Process failed to start or crashed. Blame the in-flight URI so
        # didSave can unblock it (see fix #12C invariant).
        slot.crashedUris.incl(q.uri)
        if not q.responseFuture.finished:
          q.responseFuture.complete(@[])
        continue

    let nsOpt = slot.resolvedNs
    if nsOpt.isNone:
      if not q.responseFuture.finished:
        q.responseFuture.complete(@[])
      continue

    let ns = nsOpt.get
    if ns.project.failed:
      if slot.state == SlotState.READY:
        slot.state = SlotState.CRASHED
        inc slot.crashCount
        if slot.crashCount <= MAX_CRASH_RETRIES:
          let backoffMs = if slot.crashCount > 0:
            min(1_000 * (1 shl min(slot.crashCount - 1, 14)), 30_000)
          else: 0
          if backoffMs > 0:
            await sleepAsync(backoffMs.millis)
          await execStop(slot, pool)
          slot.crashedUris.clear() # explicit restart = clean slate
          await execSpawn(slot, pool, slot.projectFile, q.uri)

        else:
          error "processQueries: crash limit reached, slot permanently failed",
            projectFile = slot.projectFile, crashCount = slot.crashCount

          if pool.notifyProc != nil:
            pool.notifyProc(
              "window/showMessage",
              %*{
                "type": 1,
                "message": fmt"Nimsuggest for {slot.projectFile} failed after {MAX_CRASH_RETRIES} attempts.",
              },
            )

          pool.removeSlot(slot.projectFile)

      slot.crashedUris.incl(q.uri)
      
      if not q.responseFuture.finished:
        q.responseFuture.complete(@[])
      continue

    slot.lastCmdTime = now()

    try:
      let queryResponse = await runNimsuggestQuery(q)
      if not q.responseFuture.finished:
        q.responseFuture.complete(queryResponse)

    except CatchableError as ex:
      debug "processQueries: query failed",
        projectFile = slot.projectFile, kind = $q.kind, msg = ex.msg
      slot.crashedUris.incl(q.uri)
      # What if the responseFuture is not finished?  How would this happen?
      if not q.responseFuture.finished:
        q.responseFuture.complete(@[]) # empty, not fail — see fix #17


# === EXECS ===
proc execSpawn*(
  slot: NimsuggestSlot, pool: NimsuggestPool, projectFile: string
): Future[bool] {.async.} =
  ## Start a nimsuggest process for `projectFile`, retrying up to MAX_CRASH_RETRIES times.
  ## Returns true if the spawn succeeded, false if all attempts failed.
  ## Sets slot.state, resolves slot.ns, and re-registers all ownedUris on success.
  ## Removes the slot from the pool on permanent failure.
  debug "execSpawn: enter",
    slotProject = slot.projectFile, projectFile = projectFile,
    slotState = $slot.state, nsIsSome = slot.ns.isSome,
    isActive = slot.isActive
  if slot.isActive and slot.ns.isSome:
    debug "execSpawn: slot already spawning/ready, skipping",
      projectFile = slot.projectFile, state = $slot.state
    return true

  slot.state = SlotState.SPAWNING
  let nsFut = newFuture[NimSuggest]("execSpawn")
  slot.ns = some(nsFut)

  while slot.crashCount <= MAX_CRASH_RETRIES:
    if slot.crashCount > 0:
      let backoffMs = min(1_000 * (1 shl min(slot.crashCount - 1, 14)), 30_000)
      debug "execSpawn: backing off before retry",
        projectFile = projectFile, backoffMs = backoffMs, attempt = slot.crashCount
      await sleepAsync(backoffMs.millis)

    debug "execSpawn: calling spawnProc",
      projectFile = projectFile, attempt = slot.crashCount + 1
    try:
      let ns = await pool.spawnProc(projectFile, @[])
      debug "execSpawn: spawnProc succeeded", projectFile = projectFile, port = ns.port
      nsFut.complete(ns)
      slot.state = SlotState.READY
      slot.crashCount = 0
      slot.lastCmdTime = now()
      if pool.statusChangedProc != nil:
        pool.statusChangedProc()
      for uri in slot.ownedUris:
        if uri notin slot.crashedUris:
          ns.openFiles.incl(uri)
          debug "execSpawn: re-registered uri", uri = uri
      return true

    except CatchableError as ex:
      inc slot.crashCount
      slot.state = SlotState.CRASHED
      error "execSpawn: spawn attempt failed",
        projectFile = projectFile, attempt = slot.crashCount, msg = ex.msg

  # All retries exhausted.
  error "execSpawn: crash limit reached, slot permanently failed",
    projectFile = projectFile, crashCount = slot.crashCount
  nsFut.fail(newException(CatchableError,
    fmt"Nimsuggest for {projectFile} failed after {MAX_CRASH_RETRIES} attempts"))
  if pool.notifyProc != nil:
    pool.notifyProc(
      "window/showMessage",
      %*{
        "type": 1,
        "message": fmt"Nimsuggest for {projectFile} failed to start after {MAX_CRASH_RETRIES} attempts. Check your nim/nimsuggest installation.",
      },
    )

  return false

proc execStop*(slot: NimsuggestSlot, pool: NimsuggestPool): Future[bool] {.async.} =
  ## Shut down the slot's nimsuggest process.
  ## ownedUris is NOT cleared — they transfer to the next spawn.
  ## In-flight queries complete with @[] because the TCP socket closes.
  ## Returns true if the slot is stopped, false if the stop proc raised.
  case slot.state
  of SlotState.STOPPING:
    # Another coroutine is already stopping this slot — wait for it to finish.
    while slot.ns.isSome:
      await sleepAsync(10.millis)
    return true

  of SlotState.READY, SlotState.SPAWNING, SlotState.CRASHED:
    slot.state = SlotState.STOPPING
    let nsOpt = slot.resolvedNs
    if nsOpt.isSome:
      debug "execStop: stopping nimsuggest", projectFile = slot.projectFile
      try:
        await pool.stopProc(nsOpt.get)
        slot.ns = none(Future[NimSuggest])
        return true
      except CatchableError as ex:
        debug "execStop: stop raised (process may already be dead)",
          projectFile = slot.projectFile, msg = ex.msg
    slot.ns = none(Future[NimSuggest])
    return false


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


