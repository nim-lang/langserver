import std/[hashes, json, options, sets, tables, times]
import chronos
import ./suggestapi_types

# === NIMSUGGEST QUERIES ===
type
  FilePosition* = object
    line*: int  ## 1-based (nimsuggest convention)
    col*: int   ## UTF-8 byte column

  NimsuggestQueryKind* {.pure.} = enum
    SUGGEST           ## sug          — completion items at position
    DEFINITION        ## def          — go-to-definition
    DECLARATION       ## declaration  — go-to-declaration
    TYPE_DEFINITION   ## type         — go-to-type-definition
    REFERENCES        ## use          — find all references
    DOCUMENT_SYMBOLS  ## outline      — file symbol tree
    WORKSPACE_SYMBOLS ## globalSymbols — workspace-wide symbol search
    HOVER              ## highlight — symbol info at position
    DOCUMENT_HIGHLIGHT ## highlight — all occurrences in file
    SIGNATURE_HELP     ## con        — overload list at call site
    INLAY_HINTS        ## inlayHints — type / parameter / exception hints
    EXPAND             ## expand — macro expansion at position
    CHANGED            ## changed — notify nimsuggest of unsaved edits (stash)
    CHECK_FILE         ## chkFile — per-file diagnostics
    CHECK_PROJECT      ## chk     — full project diagnostics
    RECOMPILE          ## recompile — force full in-process recompile
    KNOWN              ## known     — is this file in the module graph?

  NimsuggestQuery* = ref object
    id*: uint
    uri*: string
      ## Source URI. Used to resolve the on-disk path and stash path.
    dirtyFile*: string
      ## Stash path when openFiles[uri].changed is true, else "".
    responseFuture*: Future[seq[Suggest]]
      ## Completed by the query processor when nimsuggest replies.
    cancelled*: bool
      ## Set by $/cancelRequest. processQueries completes responseFuture
      ## with @[] immediately if true. Safe across coroutines (ref + single-threaded).
    case kind*: NimsuggestQueryKind
    of NimsuggestQueryKind.SUGGEST,
       NimsuggestQueryKind.DEFINITION,
       NimsuggestQueryKind.DECLARATION,
       NimsuggestQueryKind.TYPE_DEFINITION,
       NimsuggestQueryKind.REFERENCES,
       NimsuggestQueryKind.HOVER,
       NimsuggestQueryKind.DOCUMENT_HIGHLIGHT,
       NimsuggestQueryKind.SIGNATURE_HELP:
      position*: FilePosition
    of NimsuggestQueryKind.INLAY_HINTS:
      inlayHints*: tuple[start, finish: FilePosition, options: string]
    of NimsuggestQueryKind.EXPAND:
      expand*: tuple[position: FilePosition, tag: string]
    of NimsuggestQueryKind.DOCUMENT_SYMBOLS,
       NimsuggestQueryKind.WORKSPACE_SYMBOLS,
       NimsuggestQueryKind.CHANGED,
       NimsuggestQueryKind.CHECK_FILE,
       NimsuggestQueryKind.CHECK_PROJECT,
       NimsuggestQueryKind.RECOMPILE,
       NimsuggestQueryKind.KNOWN:
      discard


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
  NotifyProc* = proc(meth: string, params: JsonNode) {.gcsafe, raises: [].}
  StatusChangedProc* = proc() {.gcsafe, raises: [].}

  NimsuggestPool* = ref object
    slots*: Table[string, NimsuggestSlot]
    maxSlots*: int
    nimsuggestPath*: string  ## Path to nimsuggest binary. Set in initNimsuggestInstances.
    nimVersion*: string      ## Nim version string for logging.
    timeout*: int            ## Per-request timeout in ms.
    notifyProc*: NotifyProc
      ## Sends a JSON-RPC notification to the client (e.g. window/showMessage).
      ## Set by initLanguageServer. May be nil — check before calling.
    statusChangedProc*: StatusChangedProc
      ## Called when a slot transitions to READY or is removed.
      ## Triggers extension/statusUpdate. Set by initLanguageServer. May be nil.

proc newPool*(slots: Table[string, NimsuggestSlot], maxSlots: int): NimsuggestPool =
  NimsuggestPool(slots: slots, maxSlots: maxSlots)

proc newSlot*(projectFile: string, isEntryPoint = false): NimsuggestSlot =
  NimsuggestSlot(
    state: SlotState.SPAWNING,
    projectFile: projectFile,
    ownedUris: initHashSet[string](),
    ns: none(Future[NimSuggest]),
    queryMailbox: newAsyncQueue[NimsuggestQuery](),
    lastCmdTime: now(),
    isEntryPoint: isEntryPoint,
    crashedUris: initHashSet[string](),
  )

proc addSlot*(pool: NimsuggestPool, slot: NimsuggestSlot) =
  pool.slots[slot.projectFile] = slot

proc removeSlot*(pool: NimsuggestPool, projectFile: string) =
  pool.slots.del(projectFile)

proc canSpawn*(pool: NimsuggestPool): bool =
  pool.maxSlots == 0 or pool.slots.len < pool.maxSlots

proc slotForUri*(pool: NimsuggestPool, uri: string): Option[NimsuggestSlot] =
  for slot in pool.slots.values:
    if uri in slot.ownedUris:
      return some(slot)
  none(NimsuggestSlot)

proc assignUri*(slot: NimsuggestSlot, uri: string) =
  slot.ownedUris.incl(uri)

proc unassignUri*(slot: NimsuggestSlot, uri: string) =
  slot.ownedUris.excl(uri)
