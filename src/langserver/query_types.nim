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

# ---------------------------------------------------------------------------
# Nimsuggest query types
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# File-access query types
# ---------------------------------------------------------------------------

type
  FileAccessQueryKind* {.pure.} = enum
    DID_OPEN
    DID_CHANGE
    DID_SAVE
    DID_CLOSE
    WILL_SAVE_WAIT_UNTIL
    DID_RENAME_FILES
    DID_DELETE_FILES
    DID_CHANGE_CONFIGURATION
    FORMATTING

  FileAccessQuery* = object
    # id*: uint
    case kind*: FileAccessQueryKind
    of FileAccessQueryKind.DID_OPEN:
      didOpen*: DidOpenTextDocumentParams
    of FileAccessQueryKind.DID_CHANGE:
      didChange*: DidChangeTextDocumentParams
    of FileAccessQueryKind.DID_SAVE:
      didSave*: DidSaveTextDocumentParams
    of FileAccessQueryKind.DID_CLOSE:
      didClose*: DidCloseTextDocumentParams
    of FileAccessQueryKind.WILL_SAVE_WAIT_UNTIL:
      willSave*: WillSaveTextDocumentParams
      willSaveResponse*: Future[seq[TextEdit]]
    of FileAccessQueryKind.DID_RENAME_FILES:
      renameFiles*: RenameFilesParams
    of FileAccessQueryKind.DID_DELETE_FILES:
      deleteFiles*: DeleteFilesParams
    of FileAccessQueryKind.DID_CHANGE_CONFIGURATION:
      didChangeConfiguration*: JsonNode
    of FileAccessQueryKind.FORMATTING:
      formating*: DocumentFormattingParams
      formattingResponse*: Future[seq[TextEdit]]

# ---------------------------------------------------------------------------
# Top-level union: one item in the global dispatcher queue
# ---------------------------------------------------------------------------

type
  LangserverQueryKind* {.pure.} = enum
    NIMSUGGEST    ## Route to a per-slot queryMailbox via routeQuery.
    FILE_ACCESS   ## Execute a file operation (open/change/save/close/rename/delete).

  LangserverQuery* = object
    case kind*: LangserverQueryKind
    of LangserverQueryKind.NIMSUGGEST:
      nimsuggest*: NimsuggestQuery
    of LangserverQueryKind.FILE_ACCESS:
      fileAccess*: FileAccessQuery
