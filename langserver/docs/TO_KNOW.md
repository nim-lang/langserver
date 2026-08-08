# What You Need to Know: Nimsuggest Routing and IDE Feature Configuration

This document explains how the language server routes files to nimsuggest processes,
why the configuration of entry points matters enormously, and where the system will
surprise you. It is written for a technically-minded user who wants to understand why
their IDE features are working or not working.

---

## The Fundamental Model: nimsuggest Is a Compiler

Nimsuggest is not a symbol database. It is a **running Nim compiler** that has
compiled your project from an entry point and holds the resulting module graph in
memory. When you ask for hover information on `foo.bar`, nimsuggest looks up `bar`
in the type-checked AST of the module that defines `foo`. It cannot look up anything
it was not asked to compile.

This has one critical consequence: **nimsuggest can only serve files that are
transitively imported from its entry point**. If your entry point is `src/main.nim`
and it imports `src/utils.nim`, nimsuggest knows `utils.nim`. If `src/other.nim` is
not imported by `main.nim`, nimsuggest does not know it, and hover/completion/
definition for that file will silently return nothing.

The language server calls nimsuggest's `known` command to check whether a file is in
the module graph before routing queries to it. If `known` returns false, the file
cannot be served by that nimsuggest instance.

---

## How the Language Server Discovers Entry Points

When VS Code sends the `initialized` notification, the language server runs
`initNimsuggestInstances`:

1. It scans the workspace root for a `.nimble` file.
2. It runs `nimble dump` to extract `srcDir`, `name`, and optionally `entryPoints`.
3. It derives the main entry point as `srcDir / name & ".nim"` (e.g. `src/nimtortoise.nim`).
4. It **proactively spawns** a nimsuggest process for each discovered entry point,
   before any file is opened.

This means that for a standard single-package project, the correct nimsuggest
instance is usually already running by the time you open your first file.

**When this works well**: opening `src/langserver/dispatcher.nim` — the proactive
`src/nimtortoise.nim` nimsuggest is already running, `known dispatcher.nim` returns
true, and the file is assigned to it immediately.

**When this fails**: opening `tests/textensions.nim` — the `nimtortoise.nim`
nimsuggest was compiled from the library entry point and does not import any test
files. `known tests/textensions.nim` returns false regardless of how long you wait.
No amount of nimsuggest startup time fixes this; the module graph simply does not
reach the test file.

---

## Entry Points and Import Direction

Imports in Nim are strictly one-directional. A library entry point can never know
about its test files because test files import the library — not the other way around.

```
src/nimtortoise.nim          ←── tests/textensions.nim imports it
        │                              (but nimtortoise does NOT import textensions)
        ▼
src/langserver/dispatcher.nim
src/nimsuggest/nimsuggest_slots.nim
...
```

A nimsuggest instance started from `tests/textensions.nim` **does** know
`src/nimtortoise.nim` and all of `src/` (because textensions imports nimtortoise).
But a nimsuggest instance started from `src/nimtortoise.nim` knows nothing in
`tests/`.

There is no workaround for this at the nimsuggest level. The v4 protocol's
`unknownFile` capability is advertised but non-functional for files not in the module
graph: `needsCompilation(fileIndex)` returns false when `getModule(fileIndex)` is nil,
so no compilation occurs and all position queries return empty results.

---

## `projectMapping`: Telling the Language Server What Entry Point to Use

Without `projectMapping`, files that are not known by the proactive entry-point slot
fall through to the "orphan" path: a standalone nimsuggest is spawned with **the
individual file itself as the entry point**. This works but means each such file gets
its own nimsuggest process, burning a slot and spending cold-compile time (~11 seconds
on a clean cache).

`projectMapping` in `.vscode/settings.json` overrides this by telling the server
which entry point to use for files matching a regex:

```json
"nim.projectMapping": [
  {
    "projectFile": "src/nimtortoise.nim",
    "fileRegex": "src/.*\\.nim"
  },
  {
    "projectFile": "tests/all.nim",
    "fileRegex": "tests/.*\\.nim"
  }
]
```

**Fields** (these are the only two fields; anything else is silently ignored):

| Field | Type | Description |
|---|---|---|
| `projectFile` | string | Path to the nimsuggest entry point; relative to workspace root or absolute |
| `fileRegex` | string | Full-path regex; if matched, this entry point is used |

The regex is matched against the **full path** of the opened file, not a relative
path. Use `.*` liberally if you are uncertain whether an absolute path prefix will
appear.

### The critical rule: the entry point must transitively import the matched files

If you map `tests/.*\.nim` to `src/nimtortoise.nim`, the server will send the
`known` command to the nimtortoise nimsuggest for each test file. It will always
return false. The server will then spawn a standalone nimsuggest anyway — wasting the
time spent on the failed `known` check.

**For test files**: create a `tests/all.nim` that imports all your test modules, and
map `tests/.*\.nim` to `tests/all.nim`. A nimsuggest started from `tests/all.nim`
will transitively import every test file (and, since each test imports the library,
all of `src/` as well).

```nim
# tests/all.nim — umbrella entry point for test IDE features
import textensions
import thover
import tnimlangserver
import tprojectsetup
import tmaxlimits
# ... all other test modules
```

This file is also referenced in the `task test` in `nimtortoise.nimble`. Verify it
compiles cleanly before relying on it: `nim c --path:. tests/all.nim`. Test files
typically use `unittest2` suite/test macros, which compose cleanly when imported;
`when isMainModule:` blocks are skipped in non-main imports.

### Why the `src/` projectMapping is redundant (but not harmful)

Because `initNimsuggestInstances` already proactively spawns `src/nimtortoise.nim`
from the `.nimble` file, the `src/.*\.nim` mapping is belt-and-suspenders. The
proactive slot covers the same files. Keeping the mapping is fine — the `known`
check against the running slot will return true and the file will be assigned
correctly either way.

---

## `maxNimsuggestProcesses`, Slots, Eviction, and Consolidation

### The pool

The server maintains a pool of nimsuggest processes, each called a **slot**. Each
slot is associated with one entry point (its `projectFile`). The pool has a capacity
limit: `maxNimsuggestProcesses` in your workspace configuration (default: 1).

**Memory warning**: each nimsuggest process loads the full Nim standard library and
your project's transitive imports into memory. On a large project, a single instance
can consume 200–400 MB. Setting `maxNimsuggestProcesses: 2` means 400–800 MB peak
usage. Keep this at 1 unless you have a specific reason and enough RAM.

### Cold compile time

The first time a nimsuggest instance processes a query for a file, it must compile
the full module graph from the entry point. For a project the size of this langserver,
that takes roughly **11 seconds** from a clean NimCache. Subsequent queries are fast
(< 1 second) because nimsuggest caches the compiled AST on disk. NimCache persists
across VS Code sessions, so the cold compile only happens on the very first open
after a clean checkout or after `nim c` rebuilds the cache.

The `nimble.paths` file (generated by `nimble setup`) dramatically reduces this time
by giving nimsuggest pre-resolved `--path:` flags so it does not need to invoke
nimble internally. Always run `nimble setup` after cloning.

### Eviction: what happens when the pool is full

When `maxNimsuggestProcesses: 1` and a file is opened that requires a new slot, the
server must **evict** the existing slot to make room. Eviction policy:

1. CRASHED slots first (they are already broken)
2. STOPPING slots
3. READY slots (least recently used by actual queries)
4. SPAWNING slots (being evicted during cold compile — rare but possible)

**The eviction drops all in-flight queries for the evicted slot with empty results.**
Any open files that were assigned to the evicted slot lose their slot reference; their
`fileInfo.slot` is set to nil, and all subsequent LSP requests for those files return
empty until they are reassigned (which happens only if you close and reopen them, or
if a new slot is spawned that knows them via `isKnownByANimsuggestSlot`).

In practice, with `maxNimsuggestProcesses: 1` and a mixed `src/` + `tests/` workspace:
- Opening a test file evicts the `src/` slot (or vice versa).
- Whichever file you opened most recently has working IDE features.
- The other files have broken IDE features until you focus them again.

**The fix**: use `maxNimsuggestProcesses: 2` with separate `projectMapping` entries
for `src/` and `tests/`. The two slots coexist and eviction does not fire.

### Consolidation: new slots that subsume old ones

When a new slot spawns, it checks every other slot in the pool by asking its
nimsuggest: "do you know `<other slot's project file>`?" If yes, the new slot's
module graph is a superset of the old slot. The server then:

1. Transfers all owned URIs from the old slot to the new one.
2. Stops the old nimsuggest process.
3. Removes the old slot from the pool.

**This is intentional but has surprising consequences**: a standalone `tests/textensions.nim`
nimsuggest imports `src/nimtortoise.nim`, so it will consolidate (evict) the proactive
`src/nimtortoise.nim` slot. After consolidation, the single textensions slot serves
both `src/` files and the textensions test file.

This sounds fine, but:
- The consolidation slot's entry point is `tests/textensions.nim`, not `src/nimtortoise.nim`.
- If you later open `tests/thover.nim`, it is not in the textensions module graph
  (textensions does not import thover), so a new standalone is spawned — which then
  consolidates textensions away.
- With `maxNimsuggestProcesses: 1`, you get constant slot thrashing: whichever test
  file you opened most recently "wins".

**The fix is again the `tests/all.nim` umbrella**: a single slot from `tests/all.nim`
imports everything and does not need to be replaced when you switch between test files.

---

## The `known` Check and the v4 Protocol

When the server needs to decide whether an existing slot can serve a newly opened
file, it sends the `known` command to nimsuggest. This is a fast in-process check
(< 1 ms typically) that inspects the module graph without recompiling.

**Important**: `known` is a membership check in the module graph at the time the
query is sent. If the file was not imported by the entry point, `known` returns false
regardless of whether the file exists on disk.

**Race condition during cold compile**: `known` queries sent during the initial
cold-compile period (while nimsuggest is still building the module graph) may time
out. The server treats a timeout as "not known" and may spawn an unnecessary
standalone slot. After the cold compile completes, subsequent opens of the same file
will correctly find the slot via `isKnownByANimsuggestSlot`. This is a known
cosmetic issue; no action required.

**The v4 `unknownFile` capability does not help**: Nimsuggest advertises
`unknownFile` capability, which sounds like it should handle files not in the module
graph. In protocol v3 it did. In v4 (the only protocol the server uses), the
`needsCompilation` gate checks `getModule(fileIndex) != nil`, which is false for
unknown files, so no compilation occurs and all position queries return empty. Do not
rely on `unknownFile` as a fallback for unimported files.

---

## Nimsuggest Crashes and Recovery

Nimsuggest can crash with a SIGSEGV (notably during autocomplete on a corrupted
module graph, e.g. after a file rename). The server detects the crash via the empty
TCP response and triggers automatic restart. During restart, all in-flight queries
complete with empty results.

The crash is by design: nimsuggest's philosophy (inherited from its role as a
restartable subprocess) is "crash loudly and let the supervisor restart cleanly"
rather than "limp on with corrupted state". The SIGSEGV is the restart signal.

The `extension/suggest` command in VS Code ("Restart nimsuggest") provides a manual
restart. Files that caused a crash are tracked in `slot.crashedUris`; a `didSave` on
those files clears the block and allows recovery.

---

## What the `nim.test.entryPoint` Setting Does

The commented-out `"nim.test.entryPoint": "tests/all.nim"` in `.vscode/settings.json`
configures the **test runner** (which test file to compile and run for the
`extension/listTests` and `extension/runTests` commands). It does **not** affect
nimsuggest routing. The nimsuggest routing for test files is controlled by
`projectMapping`. These are separate concerns.

---

## Recommended Configuration for This Project

```json
// .vscode/settings.json
{
  "nim.projectMapping": [
    {
      "projectFile": "src/nimtortoise.nim",
      "fileRegex": "src/.*\\.nim"
    },
    {
      "projectFile": "tests/all.nim",
      "fileRegex": "tests/.*\\.nim"
    }
  ],
  "nim.test.entryPoint": "tests/all.nim",
  "nim.maxNimsuggestProcesses": 2,
  "nim.logNimsuggest": true
}
```

Prerequisites:
1. `nimble setup` run in the project root (generates `nimble.paths`).
2. `tests/all.nim` created and importing all test modules.
3. `nim c --path:. tests/all.nim` compiles without errors.

With this configuration, two nimsuggest instances run concurrently: one for `src/`
and one for `tests/`. No eviction occurs during normal use. Hover, completion,
definition, and inlay hints work for all files in both trees.

---

## Quick Diagnostics

**"IDE features work in `src/` but not in `tests/`"**  
→ The proactive `src/nimtortoise.nim` slot is running but cannot serve test files.
Add a `tests/all.nim` and a second `projectMapping` entry.

**"IDE features stop working after I switch between files"**  
→ `maxNimsuggestProcesses: 1` with multiple distinct entry points causes eviction.
Raise to 2 (or add a single `tests/all.nim` umbrella so both `src/` and `tests/`
are served by two complementary slots).

**"IDE features are broken for 10–15 seconds after opening a file"**  
→ NimCache is cold. Normal after a clean checkout or if NimCache was deleted. Run
`nimble setup` to ensure `nimble.paths` is present; this cuts cold-compile time
significantly.

**"Hover returns nothing even after nimsuggest is initialized"**  
→ The file is not in the module graph of the assigned slot. Check that the
`projectMapping` regex matches the file and that the mapped entry point transitively
imports it.

**"The status bar shows two nimsuggest instances with the same port"**  
→ A redirect alias is present in the pool (a leftover from an evict-and-replace
operation). Usually harmless and self-resolves on the next file open. Port
deduplication in `getLspStatus` prevents duplicate entries in the status display.