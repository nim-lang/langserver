## queues.nim
## Core logic for the slot lifecycle queue and nimsuggest query queue.
##
## Sync/async boundary
## -------------------
## SYNC  — state queries, mutations, routing policy, enqueue.
##         No await anywhere. Cooperative scheduling makes multi-field
##         mutations atomic: nothing else runs between two assignments
##         unless there is an explicit `await` between them.
##
## ASYNC — processCommands, processQueries, and the exec* helpers they call.
##         These are the ONLY coroutines. They own every await point and
##         therefore control exactly when other coroutines can observe state.
##
## The injected SpawnProc / StopProc / IsKnownProc callbacks are the only
## bridge from the sync type system into async I/O. Everything else is pure.

import std/[options, sets, tables, times, sequtils, json, strformat]
import chronos
import chronicles
import ./queue_types
import ../langserver/utils   # uriToPath, pathToUri
import ../langserver/constants # MAX_CRASH_RETRIES
import ../nim_tools/nimsuggest/nimsuggest_types
import ../nim_tools/nimsuggest/suggestapi

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc newSlot*(projectFile: string, isEntryPoint = false): NimsuggestSlot =
  NimsuggestSlot(
    projectFile: projectFile,
    ownedUris: initHashSet[string](),
    ns: none(Future[NimSuggest]),
    state: SlotState.IDLE,
    commandMailbox: newAsyncQueue[SlotCommand](),
    queryMailbox: newAsyncQueue[NimsuggestQuery](),
    isEntryPoint: isEntryPoint,
    crashedUris: initHashSet[string](),
  )

proc newPool*(
    maxSlots: int,
    spawnProc: SpawnProc,
    stopProc: StopProc,
    isKnownProc: IsKnownProc,
): NimsuggestPool =
  NimsuggestPool(
    slots: initTable[string, NimsuggestSlot](),
    maxSlots: maxSlots,
    spawnProc: spawnProc,
    stopProc: stopProc,
    isKnownProc: isKnownProc,
  )

# ---------------------------------------------------------------------------
# Sync: slot state queries (pure, no side effects)
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Sync: pool state queries (pure, no side effects)
# ---------------------------------------------------------------------------

proc liveCount*(pool: NimsuggestPool): int =
  for slot in pool.slots.values:
    if slot.isActive:
      inc result

proc canSpawn*(pool: NimsuggestPool): bool =
  pool.liveCount < pool.maxSlots

proc lruSlot*(pool: NimsuggestPool): Option[NimsuggestSlot] =
  ## The active slot with the oldest lastCmdTime. Used by EVICT_AND_SPAWN.
  ## Entry-point slots are not eligible for eviction.
  ## Returns none if every active slot is an entry point.
  var best: Option[NimsuggestSlot]
  var bestTime = dateTime(9999, mDec, 31, 23, 59, 59, 0, utc())
  for slot in pool.slots.values:
    if not slot.isActive or slot.isEntryPoint:
      continue
    let t = slot.lastCmdTime.get(dateTime(1970, mJan, 1, 0, 0, 0, 0, utc()))
    if t <= bestTime:
      bestTime = t
      best = some(slot)
  best

proc findSlot*(pool: NimsuggestPool, projectFile: string): Option[NimsuggestSlot] =
  if projectFile in pool.slots:
    some(pool.slots[projectFile])
  else:
    none(NimsuggestSlot)

proc slotForUri*(pool: NimsuggestPool, uri: string): Option[NimsuggestSlot] =
  ## Linear scan — only used for diagnostics and recovery paths,
  ## not on the hot query path (NlsFileInfo.slot is the fast lookup).
  for slot in pool.slots.values:
    if slot.ownsUri(uri):
      return some(slot)
  none(NimsuggestSlot)

# ---------------------------------------------------------------------------
# Sync: routing policy (pure function, no I/O, no side effects)
# ---------------------------------------------------------------------------

proc routingPolicy*(
    isKnown: bool,
    uri: string,
    intendedProjectFile: string,
    assignedSlot: NimsuggestSlot,
    pool: NimsuggestPool,
): RoutingResult =
  ## Given the result of the `known` command and current pool state, decide
  ## what to do next. Called by the slot processor after execCheckKnown.
  ## Returns a RoutingResult; the processor translates it into SlotCommands.

  if isKnown:
    return RoutingResult(decision: RoutingDecision.ACCEPT)

  # Cross-project: projectMapping wanted a different entry point than was
  # assigned (typically due to forced reuse when the pool was full at open time).
  if intendedProjectFile != "" and
      intendedProjectFile != assignedSlot.projectFile:
    let intendedOpt = pool.findSlot(intendedProjectFile)
    if intendedOpt.isSome and intendedOpt.get.isActive:
      # Intended slot is already running — redirect the URI there.
      return RoutingResult(
        decision: RoutingDecision.REDIRECT,
        targetProjectFile: intendedProjectFile,
      )
    # Intended slot does not exist yet — spawn it.
    if pool.canSpawn:
      return RoutingResult(
        decision: RoutingDecision.SPAWN_ALONGSIDE,
        targetProjectFile: intendedProjectFile,
      )
    let lru = pool.lruSlot
    if lru.isNone:
      return RoutingResult(decision: RoutingDecision.NO_CAPACITY)
    return RoutingResult(
      decision: RoutingDecision.EVICT_AND_SPAWN,
      targetProjectFile: intendedProjectFile,
      evictSlot: lru.get.projectFile,
    )

  # Standalone: file is in its intended project but not in the module graph
  # (not yet imported, or a new file). Spawn nimsuggest for the file itself.
  let standalonePath = uri.uriToPath
  let existingOpt = pool.findSlot(standalonePath)
  if existingOpt.isSome and existingOpt.get.isActive:
    # Already has its own standalone slot — nothing to do.
    return RoutingResult(decision: RoutingDecision.ACCEPT)

  if pool.canSpawn:
    return RoutingResult(
      decision: RoutingDecision.SPAWN_ALONGSIDE,
      targetProjectFile: standalonePath,
    )
  let lru = pool.lruSlot
  if lru.isNone:
    return RoutingResult(decision: RoutingDecision.NO_CAPACITY)
  return RoutingResult(
    decision: RoutingDecision.EVICT_AND_SPAWN,
    targetProjectFile: standalonePath,
    evictSlot: lru.get.projectFile,
  )

# ---------------------------------------------------------------------------
# Sync: slot and pool mutation
# All multi-field mutations have no await between steps, so they are atomic
# under cooperative scheduling. No other coroutine can observe a half-updated
# state because nothing else runs unless we explicitly await.
# ---------------------------------------------------------------------------

proc addSlot*(pool: NimsuggestPool, slot: NimsuggestSlot) =
  pool.slots[slot.projectFile] = slot

proc removeSlot*(pool: NimsuggestPool, projectFile: string) =
  pool.slots.del(projectFile)

proc assignUri*(slot: NimsuggestSlot, uri: string) =
  slot.ownedUris.incl(uri)

proc unassignUri*(slot: NimsuggestSlot, uri: string) =
  slot.ownedUris.excl(uri)

proc reassignUri*(fromSlot, toSlot: NimsuggestSlot, uri: string) =
  ## Move URI ownership in one atomic step (no await between the two mutations).
  fromSlot.ownedUris.excl(uri)
  toSlot.ownedUris.incl(uri)

# ---------------------------------------------------------------------------
# Sync: enqueue (addLastNoWait is non-blocking — the mailbox is unbounded)
# ---------------------------------------------------------------------------

proc send*(slot: NimsuggestSlot, cmd: SlotCommand) =
  ## Submit a lifecycle command to the slot's processor.
  ## Returns immediately; the processor picks it up on the next event loop tick.
  slot.commandMailbox.addLastNoWait(cmd)

proc query*(slot: NimsuggestSlot, q: NimsuggestQuery): Future[seq[Suggest]] =
  ## Submit an IDE query and return the response future.
  ## The caller awaits the future; the query processor completes it.
  ## If the slot crashes before the query runs, the future completes with @[].
  slot.queryMailbox.addLastNoWait(q)
  q.responseFuture

# ---------------------------------------------------------------------------
# Async: command executors (called only from processCommands)
# ---------------------------------------------------------------------------

# IMPORTANT!  I do not see thecommandMailbox nor the queryMailbox being emptied here - as they will be out of date if nimsuggest is respawning.  Everything for this slot should be xancelled.å

proc execSpawn(
    slot: NimsuggestSlot, pool: NimsuggestPool, projectFile, triggerUri: string
) {.async.} =
  ## Start a nimsuggest process for `projectFile`.
  ## Sets slot.state, resolves slot.ns, then re-registers all ownedUris.
  debug "execSpawn: enter",
    slotProject = slot.projectFile, projectFile = projectFile,
    slotState = $slot.state, nsIsSome = slot.ns.isSome,
    isActive = slot.isActive
  if slot.isActive and slot.ns.isSome:
    debug "execSpawn: slot already spawning/ready, skipping",
      projectFile = slot.projectFile, state = $slot.state
    return

  slot.state = SlotState.SPAWNING
  let nsFut = newFuture[NimSuggest]("execSpawn")
  slot.ns = some(nsFut)

  debug "execSpawn: calling spawnProc", projectFile = projectFile, triggerUri = triggerUri
  try:
    let ns = await pool.spawnProc(projectFile, @[])
    debug "execSpawn: spawnProc returned successfully", projectFile = projectFile
    nsFut.complete(ns)
    slot.state = SlotState.READY
    slot.crashCount = 0
    slot.lastCmdTime = some(now())
    debug "execSpawn: ready", projectFile = projectFile, port = ns.port
    # Notify the LanguageServer that status changed so extension/statusUpdate
    # is sent to the client reflecting the new nimsuggest instance.
    if pool.statusChangedProc != nil:
      pool.statusChangedProc()

    # Re-register all owned URIs with the fresh process.
    # ownedUris survived the spawn (or restart) so we know exactly
    # which files to tell nimsuggest about. No table lookup needed.
    for uri in slot.ownedUris:
      if uri notin slot.crashedUris:
        ns.openFiles.incl(uri)
        debug "execSpawn: re-registered uri", uri = uri

  except CatchableError as ex:
    debug "execSpawn: spawnProc raised exception",
      projectFile = projectFile, msg = ex.msg
    nsFut.fail(ex)
    slot.state = SlotState.CRASHED
    error "execSpawn: failed to spawn nimsuggest",
      projectFile = projectFile, msg = ex.msg
    inc slot.crashCount
    if slot.crashCount <= MAX_CRASH_RETRIES:
      debug "execSpawn: scheduling restart after crash",
        projectFile = projectFile, crashCount = slot.crashCount
      slot.send SlotCommand(
        kind: SlotCommandKind.RESTART,
        spawnProjectFile: slot.projectFile,
        spawnTriggerUri: "",
      )
    else:
      error "execSpawn: crash limit reached, slot permanently failed",
        projectFile = projectFile, crashCount = slot.crashCount
      if pool.notifyProc != nil:
        pool.notifyProc(
          "window/showMessage",
          %*{
            "type": 1, # MessageType.Error
            "message": fmt"Nimsuggest for {projectFile} failed to start after {MAX_CRASH_RETRIES} attempts. Check your nim/nimsuggest installation.",
          },
        )
      pool.removeSlot(projectFile)

proc execStop(slot: NimsuggestSlot, pool: NimsuggestPool) {.async.} =
  ## Shut down the slot's nimsuggest process.
  ## ownedUris is NOT cleared — they transfer to the next spawn.
  ## In-flight queries complete with @[] because the TCP socket closes.
  if slot.state notin {SlotState.READY, SlotState.SPAWNING}:
    return

  slot.state = SlotState.STOPPING
  let nsOpt = slot.resolvedNs
  if nsOpt.isSome:
    debug "execStop: stopping nimsuggest", projectFile = slot.projectFile
    try:
      await pool.stopProc(nsOpt.get)
    except CatchableError as ex:
      debug "execStop: stop raised (process may already be dead)",
        projectFile = slot.projectFile, msg = ex.msg

  slot.ns = none(Future[NimSuggest])
  slot.state = SlotState.IDLE

proc processCommands*(slot: NimsuggestSlot, pool: NimsuggestPool) {.async.}
proc processQueries*(slot: NimsuggestSlot, pool: NimsuggestPool) {.async.}

# IMPORTANT: It feels like this should be a function that returns a `RoutingDecision`, and the processing of this decision should occur in a separate function.

proc execCheckKnown(
    slot: NimsuggestSlot,
    pool: NimsuggestPool,
    uri, intendedProjectFile: string,
) {.async.} =
  ## Send `known` to nimsuggest, run routingPolicy on the result, then
  ## enqueue the follow-up SlotCommand back onto this slot's mailbox.
  ## All state changes from routing happen through SlotCommands, so they
  ## are serialised by the processor and never observed mid-transition.
  debug "execCheckKnown: enter",
    slotProject = slot.projectFile, slotState = $slot.state, uri = uri,
    intendedProjectFile = intendedProjectFile
  let nsOpt = slot.resolvedNs
  if nsOpt.isNone:
    debug "execCheckKnown: slot not ready, skipping",
      uri = uri, slotState = $slot.state
    return

  let filePath = uri.uriToPath
  var isKnown = false
  try:
    isKnown = await pool.isKnownProc(nsOpt.get, filePath)
  except CatchableError as ex:
    warn "execCheckKnown: isKnown timed out or failed, assuming unknown",
      uri = uri, msg = ex.msg

  debug "execCheckKnown: isKnown result",
    uri = uri, isKnown = isKnown,
    slotProject = slot.projectFile, intendedProjectFile = intendedProjectFile,
    poolLiveCount = pool.liveCount, poolMaxSlots = pool.maxSlots,
    poolSlotKeys = pool.slots.keys.toSeq.foldl(a & ", " & b, "")

  let routing = routingPolicy(isKnown, uri, intendedProjectFile, slot, pool)
  debug "execCheckKnown: routing decision",
    decision = $routing.decision, target = routing.targetProjectFile,
    evictSlot = routing.evictSlot

  case routing.decision
  of RoutingDecision.ACCEPT:
    debug "execCheckKnown: ACCEPT — file is known, no action", uri = uri

  of RoutingDecision.REDIRECT:
    # The intended slot is already live. Move the URI there.
    debug "execCheckKnown: REDIRECT → sending REASSIGN_URI",
      uri = uri, target = routing.targetProjectFile
    if pool.findSlot(routing.targetProjectFile).isSome:
      slot.send SlotCommand(
        kind: SlotCommandKind.REASSIGN_URI,
        reassignUri: uri,
        reassignTargetProjectFile: routing.targetProjectFile,
      )

  of RoutingDecision.SPAWN_ALONGSIDE:
    # Free slot available. Create a new slot and spawn it.
    debug "execCheckKnown: SPAWN_ALONGSIDE",
      uri = uri, target = routing.targetProjectFile,
      targetAlreadyInPool = (routing.targetProjectFile in pool.slots)
    if routing.targetProjectFile notin pool.slots:
      let newSlot = newSlot(routing.targetProjectFile)
      newSlot.state = SlotState.SPAWNING # Reserve liveCount immediately (Fix 2)
      pool.addSlot(newSlot)
      asyncSpawn processCommands(newSlot, pool)
      asyncSpawn processQueries(newSlot, pool)
      debug "execCheckKnown: SPAWN_ALONGSIDE — new slot created and coroutines scheduled",
        target = routing.targetProjectFile
    let targetSlot = pool.slots[routing.targetProjectFile]
    # Reassign the URI before spawning so re-registration includes it.
    slot.reassignUri(targetSlot, uri)
    targetSlot.send SlotCommand(
      kind: SlotCommandKind.SPAWN,
      spawnProjectFile: routing.targetProjectFile,
      spawnTriggerUri: uri,
    )
    debug "execCheckKnown: SPAWN_ALONGSIDE — SPAWN sent to target slot",
      target = routing.targetProjectFile, uri = uri

  of RoutingDecision.EVICT_AND_SPAWN:
    # At capacity. Stop the LRU slot, then spawn for the target.
    debug "execCheckKnown: EVICT_AND_SPAWN",
      uri = uri, target = routing.targetProjectFile, evict = routing.evictSlot,
      evictExists = pool.findSlot(routing.evictSlot).isSome
    let evictOpt = pool.findSlot(routing.evictSlot)
    if evictOpt.isSome:
      evictOpt.get.send SlotCommand(kind: SlotCommandKind.STOP)
      pool.removeSlot(routing.evictSlot) # remove now; slot object lives on in its coroutines
      debug "execCheckKnown: EVICT_AND_SPAWN — STOP sent and evict slot removed",
        evict = routing.evictSlot

    debug "execCheckKnown: EVICT_AND_SPAWN — creating target slot",
      target = routing.targetProjectFile,
      targetAlreadyInPool = (routing.targetProjectFile in pool.slots)
    if routing.targetProjectFile notin pool.slots:
      let newSlot = newSlot(routing.targetProjectFile)
      newSlot.state = SlotState.SPAWNING # Reserve liveCount immediately (Fix 2)
      pool.addSlot(newSlot)
      asyncSpawn processCommands(newSlot, pool)
      asyncSpawn processQueries(newSlot, pool)
      debug "execCheckKnown: EVICT_AND_SPAWN — new slot created, coroutines scheduled",
        target = routing.targetProjectFile
    let targetSlot = pool.slots[routing.targetProjectFile]
    slot.reassignUri(targetSlot, uri)
    targetSlot.send SlotCommand(
      kind: SlotCommandKind.SPAWN,
      spawnProjectFile: routing.targetProjectFile,
      spawnTriggerUri: uri,
    )
    debug "execCheckKnown: EVICT_AND_SPAWN — SPAWN sent to new target slot",
      target = routing.targetProjectFile, uri = uri,
      newPoolKeys = pool.slots.keys.toSeq.foldl(a & "," & b, "")

  of RoutingDecision.NO_CAPACITY:
    warn "execCheckKnown: pool at capacity, all slots are entry points — cannot spawn",
      uri = uri

# ---------------------------------------------------------------------------
# Async: slot command processor
# One instance runs per NimsuggestSlot, started by addSlot callers.
# Processes lifecycle commands sequentially — no two commands run in parallel
# on the same slot. The await points inside each exec* proc are the only
# moments when another coroutine can run.
# ---------------------------------------------------------------------------

proc processCommands*(slot: NimsuggestSlot, pool: NimsuggestPool) {.async.} =
  debug "processCommands: starting", projectFile = slot.projectFile
  while true:
    let cmd = await slot.commandMailbox.popFirst()
    debug "processCommands: dequeued command",
      projectFile = slot.projectFile, kind = $cmd.kind

    case cmd.kind
    of SlotCommandKind.SPAWN:
      await execSpawn(slot, pool, cmd.spawnProjectFile, cmd.spawnTriggerUri)

    of SlotCommandKind.STOP:
      await execStop(slot, pool)

    of SlotCommandKind.RESTART:
      # Exponential backoff before each crash-induced restart.
      # crashCount > 0 means execSpawn incremented it before enqueueing RESTART.
      # crashCount == 0 means a manual restart (extension/suggest) — no backoff.
      # Shift amount is capped at 14 to avoid int overflow (1 shl 14 = 16384).
      # Sequence: 1s, 2s, 4s, …, capped at 30s.
      let backoffMs =
        if slot.crashCount > 0:
          min(1_000 * (1 shl min(slot.crashCount - 1, 14)), 30_000)
        else:
          0
      if backoffMs > 0:
        debug "processCommands: backing off before restart",
          projectFile = slot.projectFile, backoffMs = backoffMs, crashCount = slot.crashCount
        await sleepAsync(backoffMs.millis)
      await execStop(slot, pool)
      slot.crashedUris.clear() # explicit restart = clean slate
      await execSpawn(slot, pool, slot.projectFile, cmd.spawnTriggerUri)

    of SlotCommandKind.REASSIGN_URI:
      let targetOpt = pool.findSlot(cmd.reassignTargetProjectFile)
      if targetOpt.isSome:
        slot.reassignUri(targetOpt.get, cmd.reassignUri)
        debug "processCommands: reassigned uri",
          uri = cmd.reassignUri, to = cmd.reassignTargetProjectFile
      else:
        warn "processCommands: reassign target slot not found",
          target = cmd.reassignTargetProjectFile

    of SlotCommandKind.RECOMPILE:
      # IMPORTANT: Should the existing nimsuggest queue be cleared when the RECOMPILE query is added to the queue, as presumably something major has changed which will probably invalidate the rest of the queue.
      let nsOpt = slot.resolvedNs
      if nsOpt.isSome:
        debug "processCommands: sending recompile", projectFile = slot.projectFile
        let q = NimsuggestQuery(
          kind: NimsuggestQueryKind.RECOMPILE,
          uri: slot.projectFile.pathToUri,
          dirtyFile: "",
          responseFuture: newFuture[seq[Suggest]]("recompile"),
        )
        slot.queryMailbox.addLastNoWait(q)

    of SlotCommandKind.CHECK_KNOWN:
      await execCheckKnown(slot, pool, cmd.checkUri, cmd.checkIntendedProjectFile)

# ---------------------------------------------------------------------------
# Async: slot query processor
# One instance runs per NimsuggestSlot alongside processCommands.
# Blocks waiting for a live process, then dispatches queries sequentially.
# In-flight queries return @[] if the process dies mid-flight (TCP close).
# ---------------------------------------------------------------------------

# proc processQueries*(slot: NimsuggestSlot, pool: NimsuggestPool) {.async.} =
#   debug "processQueries: starting", projectFile = slot.projectFile
#   while true:
#     let q = await slot.queryMailbox.popFirst()

#     # Wait until the slot has a live process.
#     # If the slot is stopped/crashed, we still drain the queue so callers
#     # get @[] rather than hanging forever.
#     if slot.ns.isSome:
#       try:
#         discard await slot.ns.get # waits for SPAWNING → READY
#       except CatchableError:
#         # Process failed to start or crashed. Blame the in-flight URI so
#         # didSave can unblock it (see fix #12C invariant).
#         slot.crashedUris.incl(q.uri)
#         if not q.responseFuture.finished:
#           q.responseFuture.complete(@[])
#         continue

#     let nsOpt = slot.resolvedNs
#     if nsOpt.isNone:
#       if not q.responseFuture.finished:
#         q.responseFuture.complete(@[])
#       continue

#     let ns = nsOpt.get

#     # Detect crash: nimsuggest died after its Future completed (TCP socket closed).
#     # project.markFailed is called by processQueue when content is empty.
#     # We detect it here before dispatching so we don't send more commands to a dead process.
#     debug "processQueries: pre-dispatch check",
#       projectFile = slot.projectFile, kind = $q.kind, uri = q.uri,
#       nsProjectFailed = ns.project.failed, slotState = $slot.state
#     if ns.project.failed:
#       debug "processQueries: nimsuggest marked failed",
#         projectFile = slot.projectFile, slotState = $slot.state,
#         crashCount = slot.crashCount, uri = q.uri
#       if slot.state == SlotState.READY:
#         slot.state = SlotState.CRASHED
#         inc slot.crashCount
#         debug "processQueries: detected nimsuggest crash, scheduling restart",
#           projectFile = slot.projectFile, crashCount = slot.crashCount
#         if slot.crashCount <= MAX_CRASH_RETRIES:
#           slot.send SlotCommand(
#             kind: SlotCommandKind.RESTART,
#             spawnProjectFile: slot.projectFile,
#             spawnTriggerUri: q.uri,
#           )
#         else:
#           error "processQueries: crash limit reached, slot permanently failed",
#             projectFile = slot.projectFile, crashCount = slot.crashCount
#           if pool.notifyProc != nil:
#             pool.notifyProc(
#               "window/showMessage",
#               %*{
#                 "type": 1,
#                 "message": fmt"Nimsuggest for {slot.projectFile} failed after {MAX_CRASH_RETRIES} attempts.",
#               },
#             )
#           pool.removeSlot(slot.projectFile)
#       slot.crashedUris.incl(q.uri)
#       if not q.responseFuture.finished:
#         q.responseFuture.complete(@[])
#       continue

#     slot.lastCmdTime = some(now())

#     let path = q.uri.uriToPath
#     debug "processQueries: dispatching",
#       projectFile = slot.projectFile, kind = $q.kind, uri = q.uri
#     try:
#       let results: seq[Suggest] =
#         case q.kind
#         of NimsuggestQueryKind.SUGGEST:
#           await ns.sug(path, q.dirtyFile, q.position.line, q.position.col)
#         of NimsuggestQueryKind.DEFINITION:
#           await ns.def(path, q.dirtyFile, q.position.line, q.position.col)
#         of NimsuggestQueryKind.DECLARATION:
#           await ns.declaration(path, q.dirtyFile, q.position.line, q.position.col)
#         of NimsuggestQueryKind.TYPE_DEFINITION:
#           await ns.type(path, q.dirtyFile, q.position.line, q.position.col)
#         of NimsuggestQueryKind.REFERENCES:
#           await ns.use(path, q.dirtyFile, q.position.line, q.position.col)
#         of NimsuggestQueryKind.DOCUMENT_SYMBOLS:
#           await ns.outline(path, q.dirtyFile)
#         of NimsuggestQueryKind.WORKSPACE_SYMBOLS:
#           await ns.globalSymbols(path, q.dirtyFile)
#         of NimsuggestQueryKind.HOVER, NimsuggestQueryKind.DOCUMENT_HIGHLIGHT:
#           await ns.highlight(path, q.dirtyFile, q.position.line, q.position.col)
#         of NimsuggestQueryKind.SIGNATURE_HELP:
#           await ns.con(path, q.dirtyFile, q.position.line, q.position.col)
#         of NimsuggestQueryKind.INLAY_HINTS:
#           await ns.inlayHints(
#             path, q.dirtyFile,
#             q.hintStart.line, q.hintStart.col,
#             q.hintEnd.line, q.hintEnd.col,
#             q.hintOptions,
#           )
#         of NimsuggestQueryKind.EXPAND:
#           await ns.expand(path, q.dirtyFile, q.position.line, q.position.col, q.expandTag)
#         of NimsuggestQueryKind.CHANGED:
#           await ns.changed(path, q.dirtyFile)
#         of NimsuggestQueryKind.CHECK_FILE:
#           await ns.chkFile(path, q.dirtyFile)
#         of NimsuggestQueryKind.CHECK_PROJECT:
#           await ns.chk(path, q.dirtyFile)
#         of NimsuggestQueryKind.RECOMPILE:
#           await ns.recompile()
#         of NimsuggestQueryKind.KNOWN:
#           await ns.known(path)
#       if not q.responseFuture.finished:
#         q.responseFuture.complete(results)
#     except CatchableError as ex:
#       debug "processQueries: query failed",
#         projectFile = slot.projectFile, kind = $q.kind, msg = ex.msg
#       slot.crashedUris.incl(q.uri)
#       if not q.responseFuture.finished:
#         q.responseFuture.complete(@[]) # empty, not fail — see fix #17
