
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
