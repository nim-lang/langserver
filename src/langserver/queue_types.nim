import std/[json, options, sets, tables, times]
import chronos
import ../nim_tools/nimsuggest/nimsuggest_types
import ../protocol/types

type
  SlotCommandKind* {.pure.} = enum
    SPAWN
      ## Start a new nimsuggest process for `spawnProjectFile`.
      ## No-op if the slot already has a live process.

    STOP
      ## Kill the slot's nimsuggest process.
      ## ownedUris is preserved — the slot survives as an empty shell
      ## so pending queries can drain and return @[].

    RESTART
      ## Stop + respawn for the same projectFile.
      ## ownedUris survives; re-registration happens automatically
      ## when the new process is ready.

    REASSIGN_URI
      ## Move `reassignUri` from this slot to the slot keyed by
      ## `reassignTargetProjectFile`. Both ownedUris sets are updated
      ## with no await between them (cooperative-schedule atomicity).

    RECOMPILE
      ## Send the `recompile` command to the live nimsuggest process.
      ## Triggers recompileFullProject in-process without a restart.
      ## Used after file rename and explicit "Clean build".

    CHECK_KNOWN
      ## Ask nimsuggest whether `checkUri` is in its module graph.
      ## The processor feeds the boolean result into routingPolicy,
      ## then enqueues the follow-up SlotCommand on the same mailbox.

  SlotCommand* = object
    case kind*: SlotCommandKind
    of SlotCommandKind.SPAWN, SlotCommandKind.RESTART:
      spawnProjectFile*: string
        ## Entry-point .nim path for the nimsuggest process.
      spawnTriggerUri*: string
        ## URI that triggered this spawn (added to ownedUris on success).

    of SlotCommandKind.STOP:
      discard

    of SlotCommandKind.REASSIGN_URI:
      reassignUri*: string
      reassignTargetProjectFile*: string

    of SlotCommandKind.RECOMPILE:
      discard

    of SlotCommandKind.CHECK_KNOWN:
      checkUri*: string
      checkIntendedProjectFile*: string
        ## What projectMapping resolved for this URI (may differ from
        ## the slot's projectFile if reuse was forced at open time).

# ---------------------------------------------------------------------------
# Routing policy result
# ---------------------------------------------------------------------------

type
  RoutingDecision* {.pure.} = enum
    ACCEPT
      ## File is known to this slot — no action needed.

    REDIRECT
      ## File belongs to a different slot that is already live.
      ## Send REASSIGN_URI to move the URI there.

    SPAWN_ALONGSIDE
      ## Pool has a free slot. Create a new slot for `targetProjectFile`
      ## and send SPAWN. No existing slot is stopped.

    EVICT_AND_SPAWN
      ## Pool is at capacity. Stop `evictSlot` (LRU) and spawn a new
      ## slot for `targetProjectFile` in its place.

    NO_CAPACITY
      ## Pool is at capacity and every slot is protected (entry points).
      ## Cannot spawn. Caller should warn the user.

  RoutingResult* = object
    decision*: RoutingDecision
    targetProjectFile*: string
      ## Project file to spawn/redirect to. Empty for ACCEPT/NO_CAPACITY.
    evictSlot*: string
      ## projectFile of the slot to stop before spawning (EVICT_AND_SPAWN only).

# ---------------------------------------------------------------------------
# Injected async callbacks
# ---------------------------------------------------------------------------

type
  SpawnProc* = proc(
    projectFile: string, nimPaths: seq[string]
  ): Future[NimSuggest] {.gcsafe, raises: [].}

  StopProc* = proc(ns: NimSuggest): Future[void] {.gcsafe, raises: [].}

  IsKnownProc* = proc(
    ns: NimSuggest, filePath: string
  ): Future[bool] {.gcsafe, raises: [].}

  NotifyProc* = proc(meth: string, params: JsonNode) {.gcsafe, raises: [].}
    ## Callback to send a window/showMessage (or any notification) to the LSP
    ## client from within the pool/queue layer, which has no direct LanguageServer
    ## reference.

  StatusChangedProc* = proc() {.gcsafe, raises: [].}
    ## Callback wired to ls.sendStatusChanged in initLanguageServer.
    ## Called when a slot transitions to READY so the client receives an
    ## up-to-date extension/statusUpdate with the new nimsuggest instance.

# ---------------------------------------------------------------------------
# Slot and pool types
# ---------------------------------------------------------------------------

type
  SlotState* {.pure.} = enum
    IDLE      ## No process. Waiting for SPAWN.
    SPAWNING  ## Spawn in progress; ns future is pending.
    READY     ## Process live; queries accepted.
    STOPPING  ## STOP running; queries return @[].
    CRASHED   ## Process exited unexpectedly; RESTART queued by processor.

  NimsuggestSlot* = ref object
    projectFile*: string
      ## Entry-point .nim path. Stable across restarts. Key in pool.slots.

    ownedUris*: HashSet[string]
      ## The single source of truth for which URIs this slot serves.

    ns*: Option[Future[NimSuggest]]
      ## none  = never spawned.
      ## Some(pending) = spawning (SPAWNING).
      ## Some(resolved, not failed) = live (READY).
      ## Some(resolved, failed) = crashed (CRASHED).

    state*: SlotState

    # commandMailbox*: AsyncQueue[SlotCommand]
      ## Lifecycle commands. processCommands dequeues one at a time.

    queryMailbox*: AsyncQueue[NimsuggestQuery]
      ## IDE query commands. processQueries dequeues and dispatches to TCP.

    lastCmdTime*: Option[DateTime]
      ## Updated after each successful query. Drives LRU eviction policy.

    isEntryPoint*: bool
      ## Discovered via nimble dump during `initialized`.
      ## Protected from idle eviction by removeIdleNimsuggests.

    crashCount*: int
      ## Incremented on unhandled exit. Reset to 0 on successful init.

    crashedUris*: HashSet[string]
      ## URIs that caused a SIGSEGV in this slot's process.
      ## Cleared by RESTART (explicit user action = clean slate).

  NimsuggestPool* = ref object
    slots*: Table[string, NimsuggestSlot]
      ## projectFile → slot. All entries are canonical (no redirect aliases).

    maxSlots*: int
      ## From NlsConfig.maxNimsuggestProcesses.

    spawnProc*: SpawnProc
    stopProc*: StopProc
    isKnownProc*: IsKnownProc
    notifyProc*: NotifyProc
      ## Optional callback wired to ls.notify in initLanguageServer.
      ## Called when a slot reaches permanent failure so the user sees an error.

    statusChangedProc*: StatusChangedProc
      ## Optional callback wired to ls.sendStatusChanged in initLanguageServer.
      ## Called when a slot transitions to READY so extension/statusUpdate is sent.
