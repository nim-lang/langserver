import std/[options, sets, strformat, tables, algorithm, os, sequtils, sugar, times]
import chronos
import chronicles
import ../protocol/[enums, types]
import ../utils/process_utils
import ./[suggestapi, suggestapi_types, nimsuggest_types]
import ../configurations/constants

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

# === EXECS ===
proc execSpawn*(
  slot: NimsuggestSlot, pool: NimsuggestPool, projectFile: string
): Future[bool] {.async.} =
  ## Start a nimsuggest process for `projectFile`, retrying up to MAX_CRASH_RETRIES times.
  ## Returns true if the spawn succeeded, false if all attempts failed.
  ## Sets slot.state, resolves slot.ns, and re-registers all ownedUris on success.
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

    debug "execSpawn: calling createNimsuggest",
      projectFile = projectFile, attempt = slot.crashCount + 1
    try:
      let project = await createNimsuggest(
        projectFile,
        pool.nimsuggestPath,
        pool.nimVersion,
        pool.timeout,
        proc(self: Nimsuggest) {.gcsafe, raises: [].} = discard,
        proc(self: Project) {.gcsafe, raises: [].} = discard,
      )
      let ns = await project.ns
      debug "execSpawn: createNimsuggest succeeded", projectFile = projectFile, port = ns.port
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
        if not nsOpt.get.project.process.isNil:
          await shutdownChildProcess(nsOpt.get.project.process)
        slot.ns = none(Future[NimSuggest])
        return true
      except CatchableError as ex:
        debug "execStop: stop raised (process may already be dead)",
          projectFile = slot.projectFile, msg = ex.msg
    slot.ns = none(Future[NimSuggest])
    return false
