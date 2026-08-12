# CLAUDE.md — nimlangserver fork context

IMPORTANT: Never connect to an MCP server!!

This is a fork of [nimlangserver](https://github.com/nim-lang/langserver). The primary
goal is to fix severe startup performance problems caused by nimble's exponential SAT
solver running during VS Code startup. The `dp-rewrite` branch is a ground-up rewrite
in `src/` with a proper module hierarchy. Historical forensic analysis, per-fix narratives,
and pre-rewrite architecture notes are in `langserver/rewrite_analysis/OLD_CLAUDE.md`.

## Branch structure

| Branch | PR target | Content |
|--------|-----------|---------|
| `fix/maxnimsuggestlimits-clean` | upstream `master` | Fixes 7–10 |
| `fix/nimsuggest-rename-recompile` | `fix/maxnimsuggestlimits-clean` | Fixes 11–21 |
| `dp-rewrite` | — | Ground-up rewrite in `src/` |

When `fix/maxnimsuggestlimits-clean` merges, rebase `fix/nimsuggest-rename-recompile`
onto upstream `master` and update its PR base.

---

## Key environmental facts

- **Two nimble binaries exist**: `~/.nimble/bin/nimble` (v0.22.2, correct) and
  `/usr/local/bin/nimble` (v0.18.2, Homebrew, older). When VS Code is **launched from
  the Dock**, PATH is limited (`/usr/bin:/bin:/usr/sbin:/sbin`), so the wrong binary is
  found via `{UsePath}`. Terminal launch inherits the full shell PATH and finds the right one.
- **The slow startup root cause** is nimble's SAT solver (`findMinimalFailingSet`, exponential)
  running during `nimble dump`. Full analysis is in `rewrite_analysis/OLD_CLAUDE.md`.
- **`nimble.paths` is gitignored** by design. Users must run `nimble setup` in the project
  root to generate it. Without it, nimsuggest's internal Nim compiler must call nimble to
  resolve every import.
- **`nimble setup`** generates `nimble.paths` containing `--noNimblePath` + one `--path:`
  per dependency. `config.nims` auto-includes this file. Running it fixed broken imports
  (chronicles, chronos, stew) immediately.
- **Cold-compilation gap is ~11 seconds** with `nimble.paths` forwarded and the correct
  nimble binary on PATH. Subsequent requests are fast (< 1s) due to NimCache on disk.
- **`$HOME` is NOT overridden** by VS Code on this machine. The `getpwuid`-based fix
  described in older issues does not apply here.

---

## Build & test commands

```sh
# Build the langserver binary:
cd langserver && nimble main

# Run all tests:
nim c --path:. -r tests/all.nim

# Run a single test file (recommended for debugging):
nim c --path:. -r tests/<file>.nim
```

Config is in `tests/config.nims`. Fixtures live in `tests/projects/`.

---

## Test file status (as of 2026-08-08)

| File | In `all.nim` | Tests | Status | Notes |
|---|---|---|---|---|
| `tsuggestapi.nim` | yes | 8 | ✓ all pass | TCP protocol + suggestapi |
| `tnimlangserver.nim` | yes | 14 | ✓ all pass | Core LSP integration |
| `tprojectsetup.nim` | yes | 3 | 1 pass / 2 FAIL | Fixture files missing (`tests/projects/testproject/src/testproject.nim`) |
| `textensions.nim` | yes | 7 | SIGSEGV | `initialized` not sent before `didOpen`; `resolvedNs` dereferences nil slot |
| `tmisc.nim` | yes | 2 | 1 FAIL + SIGSEGV | `didOpen` before `initialized`; `getLspStatus` on nil pool in unit-test context |
| `ttestrunner.nim` | yes | 3 | ✓ all pass | Test runner |
| `tfindnimblepaths.nim` | yes | 7 | ✓ all pass | `findNimblePaths` unit tests |
| `tmonorepo.nim` | yes | 5 | ✓ all pass | Previously 2 failures; now fixed |
| `tmaxlimits.nim` | yes | 4 | ✓ all pass | Spawn limit, cascade prevention, LRU |
| `tstability.nim` | yes | 13 | ✓ all pass | Stability/crash recovery scenarios |
| `tknownbug3.nim` | yes (excluded) | 1 | ✓ passes | Bug 3 may have been inadvertently fixed — investigate |
| `tmonorepo2.nim` | no | 3 | ✓ all pass | Not yet in `all.nim` |
| `tmonorepo3.nim` | no | 1 | ✓ pass | Fix #22 (redundant eviction); not yet in `all.nim` |
| `tmonorepo4.nim` | no | 1 | FAIL | Fix #12C SIGSEGV recovery; hover returns `JNull` after crash |
| `tmonorepo5.nim` | no | 3 | compiler crash | EOFError in Nim compiler during compilation |
| `thover.nim` | no | 1 | ✓ pass | Hover via stash; not yet in `all.nim` |
| `tmcp.nim` | no | — | compile error | `src/langserver/messaging_types.nim` missing |
| `troutingpolicy.nim` | no | — | file missing | Does not exist in the codebase |

### Shared infrastructure

- **`tests/fixhelpers.nim`** — `LspSocketClient`, `startServer`, `doInitialize`,
  `waitForNsInit`, `sendDidOpen/Hover/Completion/Change/Save/Rename`. Fixture path
  constants: `simpleRel`, `widgetRel`, `orphanRel`, `orphan2Rel`, `pkgbRel`, `pkgaRel`,
  `aorphanRel`.
- **`tests/tbughelpers.nim`** — multi-project helpers; `startCombinedServer(maxNs)`.
- **`tests/testhelpers.nim`** — general test utilities shared by the original test suite.
- **`tests/lspsocketclient.nim`** — LSP client for tests; uses `while` loops, not tail recursion.

**Config sequencing**: `doInitialize` advertises `workspace.configuration=true`, so the
`initialized` handler calls `maybeRequestConfigurationFromClient`. Tests needing specific
config must set `ls.configurations.currentConfig` and fire `ls.configurations.configReady`
directly after `notify("initialized")`. The guard in `maybeRequestConfigurationFromClient`
(`if ls.configurations.currentConfig.isNone`) prevents overwriting test-set config with
the client auto-response.

### Fixture projects

```
tests/projects/
  hw/                        # minimal hello-world fixture
  testproject/               # standard nimble project fixture
  testrunner/                # test runner integration fixture
  monorepo/                  # two-package monorepo
    pkgb/src/pkgb.nim         # entry point; standalone
    pkga/src/pkga.nim         # entry point; imports pkgb
             aorphan.nim      # NOT imported by pkga.nim
  simple/                    # single-package project (fixhelpers fixtures)
    src/simple.nim            # entry point; imports widget.nim
        widget.nim
        orphan.nim            # NOT imported by simple.nim
        orphan2.nim           # NOT imported by simple.nim
```

`simple/nimble.paths` and `monorepo/nimble.paths` are generated by
`generateSimpleNimblePaths()` / `generateMonorepoNimblePaths()` in fixhelpers.

---

## Known test failures (as of 2026-08-08)

#### `textensions.nim` — SIGSEGV (7 tests blocked)

All 7 extension tests crash before completing. Root cause: test sends `textDocument/didOpen`
before `initialized`, so the server waits for `initNimsuggestInstances` indefinitely.
`waitForNotificationMessage("Nimsuggest initialized …")` times out → `resolvedNs` is
called on a nil slot → SIGSEGV. Fix: ensure `notify("initialized")` is sent before `didOpen`
in the test setup.

#### `tmisc.nim` — 1 FAIL + SIGSEGV

- **Idle timeout test**: times out because `didOpen` is sent before `initialized`. Same root cause as `textensions.nim`.
- **`addProjectFileToPendingRequest` test**: SIGSEGV in `getLspStatus` — `pool` is not fully
  initialized when called from a pure unit-test context. Guard `getLspStatus` against nil pool.

If you're working on these, see `rewrite_analysis/2026-08-08_TEST_STATUS.md` for the
full stack traces.

#### `tprojectsetup.nim` — 2/3 FAIL

Fixture files missing: `tests/projects/testproject/src/testproject.nim` and
`tests/projects/testproject/src/testproject/submodule.nim` do not exist. Create them to
unblock the tests.

#### `tmonorepo4.nim` — FAIL (fix #12C SIGSEGV recovery)

Hover returns `JNull` after crash-and-recovery triggered by `didSave`. The `sug` on a
broken stash now returns results without crashing (stash content compiles successfully),
so the crash-and-recovery cycle doesn't fire as expected. Test needs to use genuinely
crash-inducing stash content, or the test premise has changed.

#### `tmonorepo5.nim` — compiler EOFError

Nim compiler crash (EOF reading a source file) prevents compilation. Exact file unknown.
Run `nim c --path:. tests/tmonorepo5.nim 2>&1 | tail -30` to identify.

#### `tmcp.nim` — compile error

`src/langserver/messaging_types.nim` does not exist. Either create this file or remove
the import from `tmcp.nim`.

#### `tknownbug3.nim` — status unclear

Previously documented as "excluded because it expects to fail". As of 2026-08-08 it
**passes** (1/1). Either Bug 3 was incidentally fixed by other changes, or the race
didn't manifest. Investigate before re-marking as excluded.

---

## Directory structure

```
src/
├── nimtortoise.nim             # entry point; main(), registerLspRoutes(), tickLs()
├── protocol/
│   ├── enums.nim               # LSP/MCP enums
│   └── types.nim               # protocol type definitions
├── configurations/
│   ├── configuration_types.nim # NlsConfig, NlsNimsuggestConfig, NlsInlayHintsConfig, …
│   └── configurations.nim      # config parsing: parseWorkspaceConfiguration, helpers
├── langserver/
│   ├── langserver.nim          # LanguageServer init, pool creation, status, tick,
│   │                           #   getNimbleDumpInfo, nsCapabilities, nsProtocolVersion
│   ├── langserver_types.nim    # LanguageServer, NlsFileInfo, LanguageServerCapabilities,
│   │                           #   LanguageServerFiles, LanguageServerMessaging,
│   │                           #   LanguageServerTransport, CommandLineParams, …
│   ├── constants.nim           # LSP version, timeout, MAX_CRASH_RETRIES
│   ├── transports.nim          # RPC transport layer (stdio / socket)
│   ├── utils.nim               # URI handling, UTF-8/UTF-16 conversion, stash paths
│   ├── configurations.nim      # getWorkspaceConfiguration, waitForWorkspaceConfiguration,
│   │                           #   getAndWaitForWorkspaceConfiguration
│   ├── diagnostics.nim         # sendDiagnostics, publishDiagnostics helpers
│   ├── dispatcher.nim          # processLangserverQueue — drains ls.langserverQueue in FIFO;
│   │                           #   handles NIMSUGGEST and FILE_ACCESS branches
│   ├── dispatcher_utils.nim    # isKnownByANimsuggestSlot, addFileToOpenFiles, queryFile,
│   │                           #   nimsuggestSlotToEvict, getLeastRecentlyUsedNimsuggestSlotInFullPool
│   ├── nimsuggest_processes.nim # getIntendedProject, getWorkingDir, getNimSuggestPathAndVersion,
│   │                           #   idleSlots, stopNimsuggestProcesses, initNimsuggestInstances
│   └── query_types.nim         # LangserverQuery (NIMSUGGEST | FILE_ACCESS variant),
│                               #   FileAccessQuery, FileAccessQueryKind
├── handlers/
│   ├── handlers.nim            # re-exports all handler submodules
│   ├── handler_utils.nim       # shared handler utilities (wrapRpc, addRpcToCancellable, …)
│   ├── notification_files.nim  # didOpen, didChange, didSave, didClose, didRenameFiles,
│   │                           #   didDeleteFiles, didChangeConfiguration
│   ├── notification_process.nim # initialized, cancelRequest, setTrace
│   ├── queries_file_access.nim # query helpers for file-level operations
│   ├── queries_nimsuggest.nim  # query helpers for nimsuggest operations
│   ├── request_extension.nim   # extension/status, extension/tasks, extension/tests, etc.
│   ├── request_process.nim     # initialize, shutdown, exit
│   ├── request_text_document.nim # textDocument/* request handlers (hover, completion, def, …)
│   └── request_workspace.nim   # workspace/* request handlers
├── nimsuggest/
│   ├── nimsuggest_types.nim    # NimsuggestQuery, NimsuggestSlot, NimsuggestPool,
│   │                           #   NimsuggestQueryKind, FilePosition, SlotState
│   ├── nimsuggest_slots.nim    # execSpawn, execStop; isLive, isActive, resolvedNs helpers
│   ├── nimsuggest_process.nim  # processNimsuggestQueries, runNimsuggestQuery
│   ├── suggestapi.nim          # nimsuggest TCP protocol: createNimsuggest, sug/def/hover/…
│   └── suggestapi_types.nim    # NimSuggest, Suggest, NimSuggestCapability, Nimsuggest
├── nimble/
│   ├── nimble.nim              # getNimbleEntryPoints
│   ├── nimble_types.nim        # NimbleDumpInfo
│   ├── nimscript_utils.nim     # nimscript helper utilities
│   └── nimscriptapi.nim        # nimscript API template
├── nim_check/
│   └── nim_check.nim           # nim check runner (nimCheck proc)
├── nim_compiler/
│   ├── nim_compiler.nim        # getNimPath, getNimVersion
│   ├── nimexpand.nim           # macro/ARC expansion
│   └── testrunner.nim          # test discovery and execution
├── nph/
│   └── formatting.nim          # nph-based document formatting
└── utils/
    ├── utils.nim               # general utility procs
    ├── asyncprocmonitor.nim    # client process monitoring (hookAsyncProcMonitor)
    └── process_utils.nim       # process utilities
```

**Import path convention**: all inter-module imports use relative paths from each file's
own directory. There is no `nim_tools/` directory — that prefix in some files is a stale
WIP artifact. Correct paths:
- `../nimble/nimble` (not `../nim_tools/nimble/nimble`)
- `../nimsuggest/[suggestapi, nimsuggest_types]` (not `../nim_tools/nimsuggest/…`)
- `../nim_check/nimcheck` (not `../nim_tools/nimcheck/nimcheck`)
- `../nim_compiler/nim_compiler` (not `../nim_tools/compiler/nim_compiler`)

---

## Key data structures

### `LanguageServer` type

Defined in `src/langserver/langserver_types.nim`:

```nim
LanguageServer* = ref object
  capabilities*:    LanguageServerCapabilities    # variant on serverMode: lsp | mcp
  configurations*:  LanguageServerConfigurations  # currentConfig + configReady AsyncEvent
  transport*:       LanguageServerTransport        # stdio or socket
  files*:           LanguageServerFiles            # open/idle files, stash, diags
  pool*:            NimsuggestPool                 # slot table + injected procs
  messaging*:       LanguageServerMessaging        # pendingRequests, responseMap, projectErrors
  lspQueue*:        AsyncQueue[LspDispatchItem]    # thin LSP dispatcher queue
  langserverQueue*: AsyncQueue[LangserverQuery]    # FIFO queue for file + nimsuggest work
  notify*:          NotifyAction
  call*:            CallAction
  onExit*:          OnExitCallback
  isShutdown*:      bool
  nimDumpCache*:    Table[string, NimbleDumpInfo]
  cmdLineClientProcessId*: Option[int]
  testRunProcess*:  Option[AsyncProcessRef]
  lsInitialized*:   Future[void]
```

`pool` is created synchronously in `initLanguageServer` (before the event loop starts)
so it is never nil. `initNimsuggestInstances` (called from the `initialized` handler)
updates `pool.maxSlots` from config and spawns entry-point slots.

`LanguageServerCapabilities` is a variant type on `serverMode`, so LSP and MCP fields
cannot be mixed at the type level.

`langserverQueue` is the single serialization point for all file and nimsuggest work.
`processLangserverQueue` (in `langserver/dispatcher.nim`) drains it in FIFO order,
guaranteeing that a `didChange` stash write is applied before any subsequent hover query
is dispatched to the per-slot mailbox.

### `NlsFileInfo` (current actual fields)

Defined in `src/nimsuggest/nimsuggest_types.nim`:

```nim
NlsFileInfo* = ref object of RootObj
  slot*:          NimsuggestSlot   # direct ref to pool slot; assigned in addFileToOpenFiles
  fingerTable*:   seq[seq[tuple[u16pos, offset: int]]]  # UTF-8 → UTF-16 mapping
  lastChanged*:   DateTime         # updated on every DID_CHANGE
  lastChecked*:   DateTime         # set when chkFile or checkProject runs for this URI
  textDocument*:  TextDocumentItem
```

Note: `changed: bool` was removed. Whether to pass the stash is now decided by `uriToStash`
(in `langserver/utils.nim`), which always returns the stash path for any file present in
`openFiles`. The stash file is written on every `DID_CHANGE`; `DID_SAVE` sends a `CHANGED`
query with an empty `dirtyFile` to tell nimsuggest to switch back to the disk file.

The slot ref is resolved synchronously during `addFileToOpenFiles` (in `dispatcher_utils.nim`)
and stored directly.

### `NimsuggestPool` and `NimsuggestSlot`

See `src/nimsuggest/nimsuggest_types.nim` for the authoritative type definitions.

```nim
NimsuggestPool* = ref object
  slots*:              Table[FilePath, NimsuggestSlot]  # projectFile → slot; all canonical (no aliases)
  maxSlots*:           int                              # pool capacity; 0 = unlimited
  fileCheckDelay*:     times.Duration                   # quiet-period before per-file diagnostics run
  nimsuggestPath*:     string                           # path to nimsuggest binary
  nimVersion*:         string                           # Nim version string for logging
  timeout*:            int                              # per-request timeout in ms
  notifyProc*:         NotifyProc                       # sends JSON-RPC notification to client
  statusChangedProc*:  StatusChangedProc                # triggers extension/statusUpdate
```

Key points:
- `pool.slots` contains only canonical entries — no redirect alias pattern from the old architecture
- Each slot has a `queryMailbox: AsyncQueue[NimsuggestQuery]`; `processNimsuggestQueries` (in `nimsuggest_process.nim`) drains it and dispatches to TCP
- There is no separate `commandMailbox`; slot lifecycle (spawn/stop) is handled directly by callers
- `slot.crashCount` is incremented on `execSpawn` failure; after `MAX_CRASH_RETRIES` the slot gives up and notifies the user
- `execSpawn` backs off exponentially between retries (`1_000 * (1 shl crashCount)` ms, capped at 30s)

---

## Module boundary intent

- `configurations/` — owns `NlsConfig` type and `parseWorkspaceConfiguration`; no LS dependency.
- `nimsuggest/nimsuggest_types.nim` — `NimsuggestQuery`, `NimsuggestSlot`, `NimsuggestPool` types.
- `nimsuggest/nimsuggest_slots.nim` — `execSpawn`, `execStop`; slot state machine.
- `nimsuggest/nimsuggest_process.nim` — `processNimsuggestQueries`, `runNimsuggestQuery`; TCP dispatch. Contains two skip-rule groups: **background queries** (INLAY_HINTS, DOCUMENT_SYMBOLS) are dropped if CHANGED pending or file edited within `FILE_CHECK_DELAY` ms; **position-based queries** (SUGGEST, SIGNATURE_HELP, HOVER, DOCUMENT_HIGHLIGHT) are dropped if a newer same-kind query is already queued for the same URI, or if CHANGED is pending.
- `nimsuggest/suggestapi.nim` — `createNimsuggest`, raw TCP protocol (sug/def/hover/chk/…).
- `langserver/dispatcher.nim` — `processLangserverQueue` (FIFO queue drain).
- `langserver/dispatcher_utils.nim` — `isKnownByANimsuggestSlot`, `addFileToOpenFiles`, `queryFile`, `nimsuggestSlotToEvict`.
- `langserver/nimsuggest_processes.nim` — `getIntendedProject`, `idleSlots`, `initNimsuggestInstances`, `stopNimsuggestProcesses`.
- `langserver/langserver.nim` — `initLanguageServer`, `tick`, `getLspStatus`, `nsCapabilities`, `nsProtocolVersion`, `getNimbleDumpInfo`.
- `handlers/` — LSP request/notification handlers; enqueue work onto `ls.langserverQueue`.

---

## The routing layer

`langserverQueue` → `processLangserverQueue` (dispatcher) → per-slot `queryMailbox`

LSP handlers enqueue work items onto `ls.langserverQueue` as `LangserverQuery` objects.
`processLangserverQueue` in `dispatcher.nim` drains the queue in FIFO order:

- `LangserverQueryKind.NIMSUGGEST` → looks up `fileInfo.slot` and calls
  `slot.queryMailbox.addLastNoWait(q)`. This is the serialization point that ensures
  stash writes precede hover queries.
- `LangserverQueryKind.FILE_ACCESS` → executes the file operation inline (DID_OPEN,
  DID_CHANGE, DID_SAVE, DID_CLOSE, etc.)

`queryFile(ls, uri, kind)` in `dispatcher_utils.nim` is the convenience wrapper: creates
a `NimsuggestQuery`, enqueues it on `fileInfo.slot.queryMailbox`, returns the
`Future[seq[Suggest]]` to await. LSP handlers call this instead of `tryGetNimsuggest`.

---

## Startup sequence

1. VS Code → `initialize`
   - Stores `lspInitializeParams`, returns server capabilities
   - Does NOT spawn nimsuggest
2. VS Code → `initialized`
   - Requests config from client (`workspace/configuration`)
   - Waits for config (with timeout — see `waitForWorkspaceConfiguration`)
   - `initNimsuggestInstances(rootPath)` — with real config; runs nimble dump to get
     `entryPoints`
3. VS Code → `textDocument/didOpen <file>`
   - `isKnownByANimsuggestSlot(pool, uri)` — checks all live slots; returns first that knows the file
   - If known → `addFileToOpenFiles(slot, textDocument)`
   - If unknown → `getIntendedProject(ls, uri)` (projectMapping regex, falls back to file itself)
   - If `pool.canSpawn` → create new `NimsuggestSlot`, `execSpawn`, then
     `asyncSpawn processNimsuggestQueries(slot, pool)`
   - If pool at capacity → `nimsuggestSlotToEvict(pool)` (LRU), drain and clear pending
     queries, `execStop`, then spawn new slot

---

## The two-table state model

The single most common source of bugs. Always think of them together:

```
ls.files.openFiles   Table[uri → NlsFileInfo]      ← LSP ground truth, all open URIs
slot.ownedUris       HashSet[uri]                   ← Per-slot tracking, subset of openFiles
```

**They are deliberately separate** — there can be multiple nimsuggest slots each owning a
disjoint subset of open files. `slot.ownedUris` tracks which URIs a given slot serves.

**They must be kept in sync manually.** Every `ls.files.openFiles` insertion/deletion must
be mirrored to the correct slot's `ownedUris` via `slot.assignUri(uri)` / `slot.unassignUri(uri)`:

| Operation | `ls.files.openFiles` | `slot.ownedUris` |
|---|---|---|
| `didOpenFile` | `openFiles[uri] = new NlsFileInfo` | `slot.assignUri(uri)` |
| `didCloseFile` | `openFiles.del(uri)` | `slot.unassignUri(uri)` |
| `didRenameFile` | del old, insert new | `unassignUri(old)`, `assignUri(new)` |
| `didDeleteFile` | `openFiles.del(uri)` | `slot.unassignUri(uri)` |

**The deadly pattern**: a `for uri in slot.ownedUris` loop that contains any `await` point.
At each `await`, the Chronos event loop yields and `didCloseFile` can call `unassignUri`,
mutating the set while the iterator is live. **Always snapshot first**: `for uri in slot.ownedUris.toSeq:`.

---

## The stash (dirtyfile) mechanism

1. `textDocument/didChange` → DID_CHANGE writes the new content to
   `storageDir/(sha1(uri) & ".nim")` (the stash), updates `fileInfo.lastChanged`.
2. When `processLangserverQueue` dispatches any nimsuggest query, it sets `q.dirtyFile`
   at dispatch time (not at query-creation time):
   - If `q.kind == CHANGED and q.saved`: `q.dirtyFile = ""` (use disk)
   - Otherwise: `q.dirtyFile = ls.uriToStash(q.uri)` — which returns the stash path for
     any file currently in `openFiles`, or `""` if the file is closed.
3. `textDocument/didSave` → enqueues a `CHANGED` query with `saved=true` and `dirtyFile=""`,
   telling nimsuggest to switch back to the on-disk file. After the `CHANGED` completes,
   `CHECK_FILE` is enqueued automatically (no stash).

**⚠ Known bug**: after `didSave`, the stash file still exists on disk. Subsequent HOVER /
INLAY_HINTS queries pass the stash path (because `uriToStash` always returns it for open
files), so nimsuggest uses the pre-save stash content instead of the saved disk content.
The `CHANGED` command cleared nimsuggest's dirty-file state, but then HOVER re-sets it.
Fix: delete (or overwrite) the stash file in `DID_SAVE` so `uriToStash` returns `""`.

In v4, nimsuggest calls `msgs.setDirtyFile(fileIndex, dirtyfile)` before any command logic,
so position commands always use the stash content when one is provided.

---

## Request pipeline

```
LSP handler
  → queryFile(ls, uri, kind)           # enqueue NimsuggestQuery on fileInfo.slot.queryMailbox
  → processNimsuggestQueries drains it
      → openTCP to slot.ns.port
      → send command string, read lines until ".\n"
      → if empty: slot transitions to CRASHED (markFailed)
      → else: parse tab-separated Suggest objects
  → map Suggest → LSP types (Location, CompletionItem, Hover, etc.)
  → respond to VS Code
```

---

## Async vs sync rule

A proc must be `{.async.}` only if it has at least one `await`. Chronos's cooperative
scheduler makes sync procs implicitly atomic — nothing else can run between two statements
in a sync proc — which is a correctness property worth preserving.

**Currently sync** (de-asynced from the original):
- `addProjectFileToPendingRequest` — pure table mutation
- `didCloseFile` — uses `asyncSpawn ls.checkFile`, not `await`
- `makeIdleFile` — calls sync `didCloseFile`
- `addFileToOpenFiles` — stash write + table mutation + slot assignment
- `queryFile` — enqueue only, returns `Future[seq[Suggest]]` for caller to await

**Invariant for infinite loops**: any `{.async.}` proc that loops indefinitely must use
`while true` + `await sleepAsync(...)`, never tail recursion (`await self()`). Each tail
call in Nim async creates a new closure-backed `Future` object that is not freed until the
entire chain resolves — which for an infinite loop means never (ORC heap corruption).

---

## Unknown-file routing / DID_OPEN branch

The old `warnIfUnknown` family is replaced by inline logic in `processLangserverQueue`'s
`DID_OPEN` branch (`dispatcher.nim`). On open:

1. `isKnownByANimsuggestSlot(pool, uri)` — checks all live slots concurrently; returns
   the first slot that knows this file, or none.
2. If known → `addFileToOpenFiles(slot, textDocument)` — assign directly.
3. If unknown → determine `projectFile` via `getIntendedProject(ls, uri)` (projectMapping
   regex lookup, falling back to the file itself as orphan entry point).
4. If `pool.canSpawn` → create new `NimsuggestSlot`, `execSpawn`, then
   `asyncSpawn processNimsuggestQueries(slot, pool)`.
5. If pool at capacity → `nimsuggestSlotToEvict(pool)` (LRU among CRASHED→STOPPING→READY→SPAWNING),
   drain and clear its pending queries, `execStop`, then spawn new slot as in step 4.

> **⚠ Known bugs in the DID_OPEN branch (2026-08-07)**:
> - (a) `execSpawn` is called with `await` inline in the queue drain coroutine, blocking
>   all other queued items for the full cold-compile time (~11s). Must be offloaded via
>   `asyncSpawn`.
> - (b) After the async `isKnownByANimsuggestSlot` call, the newly created `newSlot` is
>   not used in `addFileToOpenFiles` — the pre-spawn check result is passed instead.
> - (c) No re-entry guard exists after `await isKnownByANimsuggestSlot` returns; concurrent
>   DID_OPENs for the same URI can split ownership between two slots.
>
> See `rewrite_analysis/2026-08-07_STATE_OF_THE_REPO.md` P0/P1 for full details.

---

## `getWorkspaceConfiguration` behaviour

Three procs, different semantics:
- `getWorkspaceConfiguration()` — returns current state immediately, empty if not yet received
- `getAndWaitForWorkspaceConfiguration()` — directly awaits the shared future (deadlock risk in sync)
- `waitForWorkspaceConfiguration()` — polls with 50ms intervals, 30s timeout, safe in async;
  does NOT cancel the shared future

**Never pass `ls.configurations.configReady` (or `ls.workspaceConfiguration` in older code)
to `utils.withTimeout`** — that proc cancels the future on timeout. Cancelling a shared
future breaks all other awaiters.

---

## `nimble.paths` and `config.nims`

- `nimble setup` generates `nimble.paths` in the project root with `--noNimblePath`
  and one `--path:` per dependency.
- `config.nims` auto-includes `nimble.paths` if it exists (standard nimble workflow).
- `nimble.paths` is **gitignored** — every user must run `nimble setup` after cloning.
- `findNimblePaths` reads this file and passes its contents directly to nimsuggest,
  so the Nim compiler inside nimsuggest gets the same paths whether or not it finds
  `config.nims` itself.

---

## LSP handler map

All handlers are registered in `src/nimtortoise.nim` via `registerLspRoutes`.
Implementations are in `src/handlers/` (split across the files listed in the directory
structure above).

### Request handlers (response required)

| LSP Method | Handler file | NS Command(s) sent | Cancellable |
|---|---|---|---|
| `initialize` | `request_process.nim` | none | no |
| `textDocument/completion` | `request_text_document.nim` | `sug` | yes |
| `textDocument/definition` | `request_text_document.nim` | `def` | yes |
| `textDocument/declaration` | `request_text_document.nim` | `declaration` | yes |
| `textDocument/typeDefinition` | `request_text_document.nim` | `type` | yes |
| `textDocument/documentSymbol` | `request_text_document.nim` | `outline` | yes |
| `textDocument/hover` | `request_text_document.nim` | `highlight`, `expand`? | yes |
| `textDocument/references` | `request_text_document.nim` | `use` | no |
| `textDocument/prepareRename` | `request_text_document.nim` | `def` | yes |
| `textDocument/rename` | `request_text_document.nim` | `use` | yes |
| `textDocument/inlayHint` | `request_text_document.nim` | `inlayHints` | yes |
| `textDocument/signatureHelp` | `request_text_document.nim` | `con` | yes |
| `textDocument/formatting` | `request_text_document.nim` | none (nimpretty) | yes |
| `textDocument/documentHighlight` | `request_text_document.nim` | `highlight` | yes |
| `textDocument/codeAction` | `request_text_document.nim` | none (static list) | no |
| `workspace/executeCommand` | `request_workspace.nim` | `recompile`, `chk` | no |
| `workspace/symbol` | `request_workspace.nim` | `globalSymbols` | yes |
| `shutdown` | `request_process.nim` | none | no |
| `exit` | `request_process.nim` | none | no |
| `extension/macroExpand` | `request_extension.nim` | `expand` | no — **STUB** |
| `extension/status` | `request_extension.nim` | none | no — **STUB** |
| `extension/capabilities` | `request_extension.nim` | none | no — **STUB** |
| `extension/suggest` | `request_extension.nim` | restart/check | no — **STUB** |
| `extension/tasks` | `request_extension.nim` | none (nimble) | no |
| `extension/runTask` | `request_extension.nim` | none (nimble) | no |
| `extension/listTests` | `request_extension.nim` | none (nim compile) | no |
| `extension/runTests` | `request_extension.nim` | none (nim run) | no |
| `extension/cancelTest` | `request_extension.nim` | none | no |

### Notification handlers (no response)

| LSP Method | Handler file | NS Command(s) sent | State mutated |
|---|---|---|---|
| `initialized` | `notification_process.nim` | none | `pool`, `entryPoints` |
| `textDocument/didOpen` | `notification_files.nim` → `dispatcher.nim` | `known` | `openFiles`, pool slots |
| `textDocument/didChange` | `notification_files.nim` | none (deferred) | stash file, `lastChanged` |
| `textDocument/willSaveWaitUntil` | `notification_files.nim` | none | — |
| `textDocument/didSave` | `notification_files.nim` | `changed` (saved=true) | `crashedUris` |
| `textDocument/didClose` | `notification_files.nim` → `dispatcher.nim` | none | `openFiles`, `slot.ownedUris` |
| `workspace/didRenameFiles` | `notification_files.nim` | `recompile` | `openFiles`, `slot.ownedUris` |
| `workspace/didDeleteFiles` | `notification_files.nim` | `recompile` | `openFiles`, `slot.ownedUris` |
| `workspace/didChangeConfiguration` | `notification_files.nim` | none/restart all | config — **incomplete** |
| `$/cancelRequest` | `notification_process.nim` | none | `pendingRequests` |
| `$/setTrace` | `notification_process.nim` | none | — |

---

## Nimsuggest v3 vs v4 — critical unknown-file difference

The langserver always starts nimsuggest with `--v4`. The `unknownFile` capability is
**effectively non-functional in v4** for files that were never imported into the project:

| Version | Unknown file behaviour |
|---|---|
| v3 (`executeNoHooks`) | `graph.compileProject(dirtyIdx)` called **unconditionally** before any command — unknown files ARE compiled standalone |
| v4 (`executeNoHooksV3`) | `graph.needsCompilation(fileIndex)` gates `recompilePartially`. For an unknown file, `getModule(fileIndex)` returns nil → `needsCompilation` returns false → `recompilePartially` never called → all commands return `length=0` |

The langserver works around this by using the file itself as the nimsuggest entry point
when it detects the file is unknown to the running instance (fix #18).

---

## Known remaining issues

### P1 — Runtime bugs

1. **DID_OPEN blocks the queue**: `await execSpawn(...)` inline in `processLangserverQueue`
   blocks all subsequent queued items for ~11s cold-compile time. Must be offloaded via
   `asyncSpawn`; assign slot to `openFiles` optimistically with pending state.
2. **DID_OPEN re-entry race**: no guard after `await isKnownByANimsuggestSlot` returns;
   concurrent DID_OPENs for the same URI can split ownership between two slots.
3. **Stash persists after save** (`dispatcher.nim` DID_SAVE): the stash file is written on
   `didChange` but never deleted on `didSave`. `uriToStash` always returns the stash path
   for open files, so post-save HOVER/INLAY_HINTS pass the pre-save stash to nimsuggest.
   Fix: delete the stash file in the DID_SAVE path so `uriToStash` returns `""`.
4. **Slot eviction mailbox drain race** (`dispatcher.nim`): futures completed with `@[]`
   while `processNimsuggestQueries` may be completing the same futures — violates
   single-write invariant.

### P1 — Stub features (not yet implemented)

5. **`extension/macroExpand`** — stub; macro expansion completely unavailable.
6. **`extension/suggest` (restart action)** — stub; no manual nimsuggest restart button.
7. **`extension/status` / `extension/capabilities`** — stubs; VS Code status bar empty.
8. **Per-file diagnostics only triggered by save**: `tickFileChecks` and `checking.nim` no
   longer exist. Diagnostics (`CHECK_FILE`) are only enqueued after a `CHANGED` command
   completes in `processNimsuggestQueries`. Files that are open but not explicitly saved
   receive no periodic re-check; `lastChanged`/`lastChecked` exist on `NlsFileInfo` but
   are not currently used to drive any background polling loop.
9. **`didChangeConfiguration` incomplete** (`dispatcher.nim`): config changes to
   `nimsuggestIdleTimeout`, `projectMapping`, etc. are silently ignored.

---

## Consolidated invariants

These constraints must hold in all future code. Learned from hard-to-debug crashes.

1. **Clear `errorCallback` before `project.stop()`** — any intentional stop must set
   `project.errorCallback = none(ProjectCallback)` first. Otherwise in-flight TCP commands
   trigger `onErrorCallback` on the killed process, adding spurious entries to `crashedFiles`
   and launching a competing auto-restart. Established by fix #13/14; currently upheld in
   the `restart` template and `warnIfUnknown`. Any new code that stops a project must do the same.

2. **Snapshot `slot.ownedUris` before async iteration** — `for uri in slot.ownedUris.toSeq:` not
   `for uri in slot.ownedUris:`. Any `await` inside the loop body allows `didCloseFile` to call
   `unassignUri`, mutating the set while the iterator is live (fix #14).

3. **`didSave` must unblock `crashedFiles` before `tryGetNimsuggest`** — `tryGetNimsuggest`
   returns early if `project.failed`. Unblocking must come first so the save triggers recovery,
   not a silent no-op (fix #12 Bug C).

4. **Never pass `ls.workspaceConfiguration` to `utils.withTimeout`** — `withTimeout` cancels
   the future on timeout. `ls.workspaceConfiguration` is a shared future; cancelling it breaks
   all other awaiters (all `waitForWorkspaceConfiguration` callers). Use the polling approach in
   `waitForWorkspaceConfiguration` instead.

5. **`var p: AsyncProcessRef` in try blocks must check `if p != nil:` in `finally`** — if
   `startProcess` raises before assigning `p`, the `finally` block runs with `p = nil`.
   `shutdownChildProcess(nil)` immediately dereferences the nil ref → SIGSEGV (fix #15).

6. **`createOrRestartNimsuggest` reserves the slot before the first `await`** — the initial
   `ls.projectFiles[pf] = Project(ns: pending)` is synchronous and must remain so. Moving it
   past an `await` would allow concurrent callers to each spawn a new process for the same project.

7. **`warnIfUnknown` is fire-and-forget** — it must not block `didOpenFile`. Use
   `traceAsyncErrors` or `asyncSpawn`, not `await`. Blocking here would delay the `didOpen`
   response and prevent VS Code from sending subsequent requests.

8. **`projectErrors` in `extension/statusUpdate` shows commands that failed *after* the crash**,
   not the one that caused it. To find the triggering command, look for the last `DBG Started...`
   with no matching `DBG CPU Time` line.

9. **Use `.file` to distinguish a redirect alias from a real project entry** — after
   `ls.projectFiles[A] = ls.projectFiles[B]`, the entry at key `A` has `.file = B.file`.
   Any guard that checks "is there a good nimsuggest for key `K`?" must also verify
   `ls.projectFiles[K].file == K`. A redirect alias satisfying `ns.finished and not ns.failed`
   does not mean there is a running nimsuggest for project `K` — it means some other project
   is running and was aliased there. Violating this causes guards to falsely skip needed
   restarts (fix #18 cascade bug, `error_trace25.txt`, `error_trace26.txt`).

10. **Cascade prevention in standalone restarts** — cascade prevention only applies to the
    "kill and replace" path (redirect aliases exist only there). Check whether the project
    slot is a redirect alias (`ls.projectFiles[projectFile].file != projectFile`). If so,
    another standalone restart is already active for a different file; return early unless
    `path == projectFile`. The "spawn alongside" path never creates redirect aliases and
    does not need this guard — `shouldSpawnNimsuggest()` already prevents over-spawning.

11. **Snapshot `ls.projectFiles.keys` before iterating in `restartAllNimsuggestInstances`**
    — `createOrRestartNimsuggest` creates a sentinel entry in `ls.projectFiles` synchronously
    before the first `await`. Iterating the live key set while it mutates causes entries to
    be skipped or the iterator to observe unexpected keys. Always `for k in ls.projectFiles.keys.toSeq:`
    in any loop that calls `createOrRestartNimsuggest` inside it.

12. **Reassign `uri`'s projectFile future BEFORE calling `createOrRestartNimsuggest` in
    the "spawn alongside" path** — the addCallback re-registration loop inside
    `createOrRestartNimsuggest` checks `fileInfo.projectFile.read() == projectFile`
    (where `projectFile` is the new standalone path). If the reassignment happens AFTER the
    call, the callback may fire before the future is updated and miss adding `uri` to the
    new slot's `ownedUris`. Reassign first, then spawn.

*(Invariants 13–16 apply to the `dp-rewrite` branch architecture only.)*

13. **`execSpawn` must not be `await`-ed inline in `processLangserverQueue`** — the queue
    drain coroutine is the single FIFO serialization point for all LSP work. Blocking it
    with `await execSpawn(...)` during cold-compile (~11s) freezes hover/completion/definition
    for all already-open files for the full duration. Always offload spawns via `asyncSpawn`
    and assign the file to `openFiles` optimistically with a pending slot state.

14. **Re-entry guard required after every `await` in DID_OPEN** — between
    `isKnownByANimsuggestSlot` (async) and `addFileToOpenFiles`, another coroutine can open
    the same URI. After every `await` in the DID_OPEN path, re-check `if uri in
    ls.files.openFiles` before proceeding. A single guard before the first `await` is
    insufficient.

15. **Stash path uses SHA-1** (`langserver/utils.nim`: `uriStorageLocation`) — fixed.
    `secureHash(string(uri)) & ".nim"` gives ~2^-80 collision probability, acceptable.
    Previous versions used `hash(uri).toHex` (64-bit, collision-prone); that is gone.

16. **Guard `fileInfo.slot` before use in `didClose`/`didSave` paths** — `slot` in
    `NlsFileInfo` may be nil if `didClose` fires for a URI whose `didOpen` has not yet
    completed slot assignment (nimsuggest still cold-compiling). Always check
    `if fileInfo.slot != nil:` before `fileInfo.slot.unassignUri(uri)` or accessing
    `fileInfo.slot.queryMailbox`.

---

## Debugging approach

Add `debug "..."` calls with the `chronicles` library. The VS Code LSP trace log
(`"nim.logNimsuggest": true`) captures both protocol messages (timestamped) and
langserver debug output in one file. Debug logs at all nimble call sites print `HOME`,
`PATH`, and `NIMBLE_DIR` to identify which binary is being used. When investigating
crashes, check `projectErrors` in `extension/statusUpdate` for post-crash failed commands,
then search backwards in the log for the last `DBG Started...` with no matching
`DBG CPU Time` to find the command that triggered the crash.
