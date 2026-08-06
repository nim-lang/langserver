import chronos
import ../nim_tools/nimsuggest/nimsuggest_types
import ../protocol/types

# === NIMSUGGEST SLOT TYPES ====

type
  SlotState* {.pure.} = enum
    # IDLE      ## No process. Waiting for SPAWN.
    SPAWNING  ## Spawn in progress; ns future is pending.
    READY     ## Process live; queries accepted.
    STOPPING  ## STOP running; queries return @[].
    CRASHED   ## Process exited unexpectedly; RESTART queued by processor.

  NimsuggestSlot* = ref object
    state*: SlotState
    projectFile*: string # Entry-point .nim path. Stable across restarts. Key in pool.slots.
    ownedUris*: HashSet[string]
      ## The single source of truth for which URIs this slot serves.
    ns*: Option[Future[NimSuggest]]
      ## none  = never spawned.
      ## Some(pending) = spawning (SPAWNING).
      ## Some(resolved, not failed) = live (READY).
      ## Some(resolved, failed) = crashed (CRASHED).
    queryMailbox*: AsyncQueue[NimsuggestQuery]
      ## IDE query commands. processQueries dequeues and dispatches to TCP.
    lastCmdTime*: DateTime
      ## Updated after each successful query. Drives LRU eviction policy.
    isEntryPoint*: bool
      ## Discovered via nimble dump during `initialized`.
      ## Protected from idle eviction by removeIdleNimsuggests.
    crashCount*: int
      ## Incremented on unhandled exit. Reset to 0 on successful init.
    crashedUris*: HashSet[string]
      ## URIs that caused a SIGSEGV in this slot's process.
      ## Cleared by RESTART (explicit user action = clean slate).

# === NIMSUGGEST POOL TYPES === 
type 
  NimsuggestPool* = ref object
    slots*: Table[string, NimsuggestSlot]
    maxSlots*: int
