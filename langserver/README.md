# Nim Tortoise Language Server

## "Slow and steady wins the race"

A Language Server for `nim` that prioritises correctness over speed.

A fork and rewrite of [`nimlangserver`](https://github.com/nim-lang/langserver). It aims to solve a number of problems when using the combination of `nimlangserver` and its accompanying VS Code extension on large projects, especially monorepos containing a number of different Nim packages.

Earlier in this project, pull requests for many of the improvements were submitted to the main `nimlangserver` repository. Over time, however, it became clear that several architectural choices in the original necessitated a ground-up rewrite of its internals.

---

## The Problem

On large projects you will frequently see:

- Slow start-up times (over a minute before any highlighting appears in VS Code).
- Highlighting, mouseover and inlays break after 10–15 minutes of use or after jumping between many files.
- Highlighting and mouseover frequently show outdated (stale) information.
- The configured `maxNimsuggestProcesses` limit is not respected — every open editor tab spawns its own process.
- Moving a file in the VS Code explorer breaks all language features for the relocated file.
- Diagnostic squiggles only update on file save, not while editing.

---

## How nimsuggest and the Language Server Work Together

Understanding this relationship is the key to a well-functioning setup. Most configuration mistakes come from misunderstanding one or more of these points.

### What nimsuggest is

`nimsuggest` is a command-line tool that ships with the Nim compiler. Its job is to answer questions about Nim source code: "what type is this symbol?", "where is this proc defined?", "what completions are valid here?". It does this by fully compiling a Nim project in memory and then responding to queries from an editor.

`nimsuggest` is not a simple file parser. It runs a real Nim compilation. It needs to know the **entry point** of the project — the single `.nim` file that, when compiled, pulls in all the code that should be visible in the editor. This is analogous to passing a file to `nim c file.nim`. It can only answer questions about code that is reachable from that entry point.

The upside is that once the initial compilation completes, `nimsuggest` responds to queries very quickly (< 1 second) because the compiled module graph is held in memory. The downside is that startup takes as long as a full cold compile — seconds to tens of seconds, depending on the size of the import tree.

### How the language server chooses a nimsuggest root

When you open a `.nim` file, the language server must choose an entry point file to pass to `nimsuggest`. It does this in two stages:

**Stage 1 — nimble project detection (preferred):** the server walks up the directory tree from the opened file looking for the nearest `.nimble` file. Once found, it runs `nimble dump` to read the `entryPoints` field, which specifies the correct `.nim` file for `nimsuggest` to use as its root.

If `entryPoints` is not set in the `.nimble` file, the server does not know which file to use. It falls back to launching `nimsuggest` with the *opened file itself* as the root. This is almost always wrong: `nimsuggest` then only sees that one file and its direct imports, so it cannot provide completions or navigation for the rest of the package. Multiple `nimsuggest` processes accumulate, one per opened file.

**Stage 2 — `projectMapping` fallback:** the `nimTortoise.projectMapping` setting in `.vscode/settings.json` maps file-path regexes to explicit project root files. This is the fallback when no `.nimble` file is found, and a useful safety net in any case. See configuration details below.

**Setting `entryPoints` in every `.nimble` file is the single most important configuration step.**

### The nimsuggest process pool

The language server maintains a pool of `nimsuggest` processes. `nimTortoise.maxNimsuggestProcesses` caps how many run simultaneously. When a new file is opened that is not known to any running process, the server either spawns a new slot (if under the cap) or evicts the least-recently-used slot (if at the cap) before spawning.

Each `nimsuggest` process handles a specific project entry point. Files that are part of the same project (reachable via imports from that entry point) are routed to the same process. Files in a different project are routed to a different process or trigger a new spawn.

### Why CPU spikes when you open a new package

When `nimsuggest` starts, it performs a full Nim compilation in memory. For a package that transitively imports a large codebase, this can take 10–60 seconds and will use 100% of one CPU core during that time. This is normal behaviour, not a bug. Once the initial compilation is complete, CPU usage drops to near zero.

If CPU usage stays high indefinitely, the most likely causes are:
- `nimsuggest` is crashing and restarting in a loop (check `entryPoints` in the `.nimble` file)
- Two Nim extensions are active simultaneously, each managing their own process pool
- The compiler cache contains stale artifacts — clear with `rm -rf ~/.cache/nim`

The language server mitigates restart loops with exponential backoff (1s, 2s, 4s, …, capped at 30s) and sends a VS Code notification after repeated failures.

---

## Best Practices: Project Setup

### 1. Set `entryPoints` in every `.nimble` file

Every `.nimble` file should declare an `entryPoints` field pointing to the main `.nim` file for that package. This is the same file you would pass to `nim c` to build the package.

```nim
# Library package with source in src/
srcDir      = "src"
entryPoints = @["src/mypackage.nim"]
```

```nim
# Binary package at the project root
bin         = @["mymain"]
entryPoints = @["mymain.nim"]
```

The path in `entryPoints` is relative to the `.nimble` file's location.

**Update `entryPoints` immediately whenever you rename or move a package.** A stale path pointing to a non-existent file causes `nimsuggest` to crash on startup for every file in that package — silently, with no diagnostic in the editor.

A well-formed `.nimble` file looks like:

```nim
version     = "1.0.0"
author      = "Your Name"
description = "What this package does."
license     = "MIT"

srcDir      = "src"
entryPoints = @["src/mypackage.nim"]

requires "nim >= 2.2.0"
```

#### What happens if `entryPoints` is wrong

| Mistake | Effect |
|---------|--------|
| `entryPoints` not set | `nimsuggest` launches with the opened file as root. Completions only work for that one file; multiple processes accumulate. |
| Path in `entryPoints` does not exist | `nimsuggest` crashes on every startup for any file in the package. |
| Trailing space in the path | The OS cannot find the file. `nimsuggest` crashes silently. |
| Stale path after a rename | Same as path not existing. |

### 2. Use the standard double-naming layout

Nim packages follow a specific directory layout. Understanding it is essential before setting up import paths.

Given a package called `mypackage`, the layout is:

```
mypackage/
  mypackage.nimble
  config.nims
  src/
    mypackage.nim        ← entry point; aggregates and re-exports everything below
    mypackage/           ← subdirectory named the same as the package
      submodule_a.nim
      submodule_b/
        submodule_b.nim  ← aggregator: imports and re-exports parts.nim, utils.nim
        parts.nim
        utils.nim
```

The double naming keeps public import paths clean. When another package adds `mypackage/src` to its search path, callers write:

```nim
import mypackage              # resolves to src/mypackage.nim
import mypackage/submodule_a  # resolves to src/mypackage/submodule_a.nim
```

`src/mypackage.nim` itself is a pure aggregator — it imports all public submodules and re-exports them, and contains no logic of its own. This is the file you give to `nimsuggest` as its root: by importing the entry point, it sees everything in the package.

```nim
# src/mypackage.nim
import ./mypackage/submodule_a
import ./mypackage/submodule_b/submodule_b
export submodule_a, submodule_b
```

### 3. Configure `config.nims` correctly

When the Nim compiler (or `nimsuggest`) processes any `.nim` file, it automatically reads the nearest `config.nims` file found while walking up the directory tree. This file can add directories to the compiler's search path, which is how a package's `nimsuggest` instance finds sibling packages in a monorepo.

#### Use `thisDir()`, not `$projectDir`

This is the most common mistake in `config.nims` files:

| Expression | Resolves to |
|------------|-------------|
| `thisDir()` | The directory containing the `config.nims` file — **always correct** |
| `$projectDir` | The directory containing the `.nim` file being compiled — **changes with each file** |

`$projectDir` is wrong for package-level `config.nims` files because when `nimsuggest` or `nim c` compiles a file deep inside `src/`, `$projectDir` resolves to that deep directory — not to the package root where `config.nims` lives.

**Example of the bug:**

```
mypackage/              ← config.nims lives here
  config.nims
  src/
    mypackage/
      deep.nim          ← being compiled; $projectDir = mypackage/src/mypackage/
```

With `$projectDir`:
```nim
switch("path", "$projectDir/../other/src")
# resolves to: mypackage/src/mypackage/../other/src
#            = mypackage/src/other/src    ← WRONG, does not exist
```

With `thisDir()`:
```nim
switch("path", thisDir() & "/../other/src")
# resolves to: mypackage/../other/src
#            = other/src                  ← CORRECT
```

**Always use `thisDir()` in `switch("path", ...)` calls in package-level `config.nims` files.**

#### Standard `config.nims` template

```nim
# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

# Add sibling packages to the search path.
# thisDir() = the directory containing this config.nims file.
switch("path", thisDir() & "/../other_package/src")
switch("path", thisDir() & "/../../external/some_lib/src")
```

The `--noNimblePath` line prevents the global Nimble cache at `~/.nimble/pkgs2/` from interfering with your local copies. Without it, a stale installed version of a package you are actively developing can silently shadow your local changes.

The `nimble.paths` include handles external dependencies from the `.nimble` `requires` section. Run `nimble setup` in the project root to generate this file.

### 4. Declare all transitive path dependencies in the top-level `config.nims`

This is one of the most subtle and common sources of hard-to-diagnose errors.

**A library's own `config.nims` is never consulted when that library is imported by another package.** Only the `config.nims` files in the ancestry of the *top-level entry point* are read.

Consequence: **every `switch("path", ...)` entry needed by any file in the entire transitive import closure must be present in the top-level package's `config.nims`**.

A concrete example: package A imports B, and B imports C:

```
entry.nim
  └── imports A (declared in entry's config.nims ✓)
        └── imports B (declared in entry's config.nims ✓)
              └── imports C (must ALSO be in entry's config.nims — easy to miss ✗)
```

B's own `config.nims` declares C because B needs it when running its own tests. But that declaration is invisible to the top-level build. When the compiler reaches the `import C` inside B, it fails with `Error: cannot open file: C`, but the error appears to come from inside B's source — which makes it look like a problem with B, not with the top-level package that forgot to declare C's path.

**The fix:** add the missing path to the failing top-level package's `config.nims`:

```nim
switch("path", thisDir() & "/path/to/C/src")
```

**How to find the missing package:** the error `cannot open file: <name>` identifies it. To find where it lives:

```bash
find . -name "<name>.nim" -not -path "*/\.*"
```

**When to remember this:** whenever you add a new import to a shared library, the library's `config.nims` is updated and the library's own tests pass. But every top-level package that depends on the library silently inherits the new transitive dependency and will only fail when someone actually builds it. Proactively update all top-level `config.nims` files when adding dependencies to shared libraries.

### 5. Run `nimble setup` to generate `nimble.paths`

`nimble setup` generates a `nimble.paths` file in the project root containing `--noNimblePath` and one `--path:` entry per external dependency. The standard `config.nims` template auto-includes this file.

With `nimble.paths` present, `nimsuggest`'s internal Nim compiler resolves all imports from pre-computed paths without ever calling nimble. This reduced cold-compile time in our testing from ~53 seconds to ~11 seconds.

`nimble.paths` is gitignored — every developer must run `nimble setup` after cloning.

### 6. Configure `.vscode/settings.json`

Even with `entryPoints` set correctly, it is worth keeping `nimTortoise.projectMapping` accurate as a safety net, particularly for test files that live outside the `src/` directory.

#### `nimTortoise.maxNimsuggestProcesses`

```json
"nimTortoise.maxNimsuggestProcesses": 1
```

Limits how many `nimsuggest` processes run simultaneously. The default (`0`) is unlimited: a separate process can accumulate for every package opened in the session, each consuming several hundred megabytes and rebuilding the dependency graph independently.

`1` is the most conservative setting. The trade-off is a startup delay (5–30 seconds) each time you switch to a file in a different package. For a repository where you frequently edit files across many packages, `3` or `4` keeps recently-used packages warm.

#### `nimTortoise.nimsuggestIdleTimeout`

```json
"nimTortoise.nimsuggestIdleTimeout": 300000
```

Milliseconds before an idle `nimsuggest` process is stopped. `300000` = 5 minutes. Increase this if you want processes to stay alive longer when switching between packages.

#### `nimTortoise.projectMapping`

Each entry maps a regex (matched against the file path) to a project entry-point file:

```json
{
  "fileRegex":   "mypackage/(src|tests)/.*\\.nim",
  "projectFile": "mypackage/src/mypackage.nim"
}
```

Note the `(src|tests)` pattern. Without it, opening a test file launches `nimsuggest` with the test file as root, which cannot see the library it is testing.

**Keep `projectMapping` in sync with the files on disk.** When you rename a package, update both `entryPoints` in the `.nimble` file and the `projectFile` in `projectMapping`. A mapping whose `projectFile` points to a non-existent file causes `nimsuggest` to crash for every matched file.

#### Common mistakes in `projectMapping`

| Mistake | Effect |
|---------|--------|
| `"fileRegex": "src/.*\\.nim"` without a package prefix | Matches files in every package's `src/`, routing them all to one wrong root |
| Trailing space in `projectFile` | `nimsuggest` cannot open the file and crashes |
| `projectFile` references a non-existent file | `nimsuggest` crashes on startup for any matched file |
| Forgetting `tests/` in the regex | Test files launch `nimsuggest` with the test file as root |
| Stale entries after a package rename | Same as referencing a non-existent file |

#### Full example for a multi-package repository

```json
{
  "nimTortoise.maxNimsuggestProcesses": 2,
  "nimTortoise.nimsuggestIdleTimeout": 300000,
  "nimTortoise.projectMapping": [
    {
      "projectFile": "packages/core/src/core.nim",
      "fileRegex":   "packages/core/(src|tests)/.*\\.nim"
    },
    {
      "projectFile": "packages/server/src/server.nim",
      "fileRegex":   "packages/server/(src|tests)/.*\\.nim"
    },
    {
      "projectFile": "packages/client/src/client.nim",
      "fileRegex":   "packages/client/(src|tests)/.*\\.nim"
    }
  ]
}
```

---

## Verifying Your Setup

### Check which processes are running

```bash
ps aux | grep -E "nimsuggest|nimlangserver" | grep -v grep
```

Each line shows the full command used to launch the process. The path after `nimsuggest` is the entry-point file. It should match the `entryPoints` value in the package's `.nimble` file.

If you see a file that is not a package entry point (e.g. a file deep inside `src/utils/`), `entryPoints` is not set correctly in the `.nimble` file.

### Check that entry-point files exist

```bash
for f in "pkg_a/src/pkg_a.nim" "pkg_b/src/pkg_b.nim"; do
  [ -f "$f" ] && echo "OK      $f" || echo "MISSING $f"
done
```

Run this for every path in your `entryPoints` declarations and `projectMapping` entries.

### Check that `nim` and `nimsuggest` versions match

The `nimsuggest` binary must match the version of the `nim` compiler used to build the project. A mismatch causes crashes or incorrect analysis because the two tools reference different stdlib trees.

```bash
nim --version | head -1
nimsuggest --version | head -1
# Both must report the same version number.
```

If they differ, ensure `PATH` resolves both commands to the same Nim installation.

### Check the search paths `nimsuggest` uses

```bash
nim dump src/mypackage.nim 2>&1 | grep "lib\|path"
```

The output lists every directory on the search path. Verify that all packages your code imports are present.

### Clear the compiler cache if behaviour is unexpected

`nimsuggest` uses the same incremental compilation cache as `nim c`, stored at `~/.cache/nim/`. Over time it can accumulate stale artifacts from renamed files, changed compiler flags, or interrupted builds.

```bash
rm -rf ~/.cache/nim
```

This is safe — the cache is rebuilt automatically on the next build or `nimsuggest` startup. Consider clearing it after:
- A significant refactor or package rename
- Changes to `passC`/`passL` pragmas or compiler flags
- Situations where completions look correct but go-to-definition is wrong

---

## Setup Checklist

### Setting up a new package

- [ ] Use the double-naming layout: `pkg/src/pkg.nim` as the entry point, `pkg/src/pkg/` for submodules
- [ ] Add `entryPoints = @["src/pkg.nim"]` to the `.nimble` file and verify the file exists
- [ ] Create `pkg/config.nims` with `thisDir()`-based `switch("path", ...)` entries for every sibling dependency
- [ ] If this package will be imported by other top-level packages, update **every top-level `config.nims`** to also declare this package's path (search paths are entry-point-relative, not library-relative)
- [ ] Run `nimble setup` to generate `nimble.paths`
- [ ] Add an entry to `.vscode/settings.json` under `nimTortoise.projectMapping` covering both `src/` and `tests/` subdirectories
- [ ] Verify the `projectFile` path has no trailing spaces and the file exists

### When renaming or moving a package

- [ ] Update `entryPoints` in the `.nimble` file to the new path
- [ ] Update `projectFile` in `.vscode/settings.json`
- [ ] Update all `switch("path", ...)` entries in `config.nims` files of packages that depend on the renamed package
- [ ] Clear the nim cache: `rm -rf ~/.cache/nim`

### Ongoing checks

- [ ] Only one Nim VS Code extension is active at a time
- [ ] `nimTortoise.maxNimsuggestProcesses` is set to a sensible value (not `0` on large monorepos)
- [ ] After opening a new package, `ps aux | grep nimsuggest` shows the expected entry-point file
- [ ] If CPU stays high indefinitely, check for a crash loop: repeated crashes produce repeated notification toasts in VS Code, and backoff delays (1s, 2s, 4s…) visible in the language server output panel

---

## Root Causes in the Original `nimlangserver`

The improvements in this fork address several interacting architectural problems:

### 1. Nimble's SAT solver on the critical path

When VS Code is launched from the Dock rather than a terminal, its `PATH` is minimal. The extension would pick up an older Homebrew `nimble` instead of the correct `~/.nimble/bin/nimble`. The older binary cannot find the required Nim version in its database, causing `findMinimalFailingSet` — an exponential-time UNSAT prover — to run to completion before `nimble dump` produced a single byte of output. This was the primary cause of the 1+ minute startup delay.

Additionally, without `nimble.paths` forwarded to nimsuggest, the Nim compiler inside nimsuggest had to call nimble for every unresolved import, hitting the SAT solver repeatedly on a cold start.

### 2. `maxNimsuggestProcesses` effectively ignored

The limit was checked in some places but bypassed at three spawn sites (`getProjectFile` for regex-matched files, `initNimsuggestInstances` for entry points, `getNimsuggestInner` for missing project keys). On startup, multiple `didOpen` requests arrive simultaneously. All of them checked the count before any single nimsuggest had finished starting and all saw zero — so all spawned unconditionally, regardless of the configured limit.

### 3. Race conditions from uncontrolled async

Concurrent LSP handlers called nimsuggest and the suggestapi procs directly, sharing the same TCP socket with no serialisation. This broke LRU tracking, caused concurrent writes to the same TCP connection, and meant there was no guarantee nimsuggest was ready before a command was sent.

A deeper version of this problem: the same table held both canonical project entries and redirect aliases. Every code path had to reason about whether it was looking at a real entry or a stale alias. Two separate tracking sets had to be kept in sync by convention at every mutation site, with no structural enforcement.

### 4. Mishandled `nimsuggest` lifecycle

- `checkFile` called `chkFile` without first calling `changed()`, so nimsuggest checked the stale cached AST from the last save. Squiggles only updated on save.
- `workspace/didRenameFiles` had no handler. After a file move, the stash buffer was stranded at the old path.
- Nimsuggest was spawned from the `initialize` handler, before VS Code had sent the `workspace/configuration` response — so `projectMapping` and `maxNimsuggestProcesses` were always default at spawn time.
- After a crash and restart, only the single URI that triggered the respawn was re-registered. All other editor tabs were silently absent.
- Crash loops ran at full speed with no backoff.

---

## Architecture & Refactor

The rewrite (`dp-rewrite` branch) addresses all of these root causes with a clean architecture designed around two principles: **serialise all state mutations** and **make ownership explicit at the type level**.

### Queue-based dispatcher

All LSP work flows through a two-level queue system:

```
LSP handler
  → ls.langserverQueue          (single FIFO queue)
  → processLangserverQueue      (drains in order)
      → FILE_ACCESS branch      (didOpen, didChange, didSave, didClose, …)
      → NIMSUGGEST branch       → slot.queryMailbox (per-slot FIFO)
                                → processNimsuggestQueries (TCP dispatch)
```

`ls.langserverQueue` is the single serialisation point for all file and nimsuggest work. Because `processLangserverQueue` drains it in FIFO order, a `didChange` stash write is guaranteed to be applied before any subsequent hover query is dispatched to the per-slot mailbox. There is no race between "write the stash" and "read the stash".

Each `NimsuggestSlot` has its own `queryMailbox`. `processNimsuggestQueries` (one coroutine per slot) drains it and dispatches to the nimsuggest TCP socket. Commands for the same slot are serialised; commands for different slots run concurrently. The "thin dispatcher" pattern means the top-level LSP message dispatcher never awaits handler results — it only `asyncSpawn`s — so it cannot become a bottleneck.

### Single-table ownership model

The old architecture used a redirect-alias pattern: `ls.projectFiles[A] = ls.projectFiles[B]` as a shorthand for "files that used to be served by A are now served by B". Every guard had to check `ls.projectFiles[K].file == K` to distinguish a real entry from an alias.

The rewrite eliminates this entirely. Each `NlsFileInfo` holds a direct `slot: NimsuggestSlot` reference. The slot is the stable identity — it survives process restarts, can be queued to, and owns the set of URIs assigned to it. There are no redirect aliases.

File ownership is tracked in exactly two places:
- `ls.files.openFiles[uri].slot` — "which slot owns this file?"
- (slot) `ownedUris` — "which files does this slot own?"

Both are updated together, synchronously, with no `await` between them. Under Chronos's cooperative scheduler, the absence of an `await` between two statements is sufficient for atomicity.

### Module hierarchy

The rewrite uses a clean module structure with no import cycles:

```
src/
├── configurations/      — NlsConfig type; no LanguageServer dependency
├── langserver/          — LanguageServer type, dispatcher, transports
├── handlers/            — LSP request/notification handlers (enqueue onto langserverQueue)
├── nimsuggest/          — NimsuggestSlot, pool, TCP protocol (suggestapi)
├── nimble/              — nimble dump, entry point discovery
├── nim_check/           — nim check runner
├── nim_compiler/        — nim binary discovery, macro/ARC expansion, test runner
├── nph/                 — nph-based document formatting
└── utils/               — general utilities, async process monitor
```

Handlers enqueue work onto `langserverQueue` and never touch `suggestapi` directly. The dispatcher is the only code that routes between the queue and per-slot mailboxes.

### Correct nimsuggest lifecycle

- **Spawned after config**: `initNimsuggestInstances` is called from the `initialized` handler (after `workspace/configuration` is received), so `projectMapping` and `maxNimsuggestProcesses` are always correct at spawn time.
- **`nimble.paths` forwarding**: `findNimblePaths` walks up the directory tree to the nearest `nimble.paths` file and passes its `--path:` entries directly to nimsuggest. The internal Nim compiler resolves all imports from disk without calling nimble. This reduced cold-compile time from ~53 seconds to ~11 seconds.
- **Live diagnostics**: `checkFile` calls `changed()` with the stash path before `chkFile`, so nimsuggest always checks the live editor buffer. Squiggles update while you type.
- **Rename handling**: `workspace/didRenameFiles` migrates stash file, `openFiles` entry, and triggers `recompile` on the running nimsuggest instance — cheap (preserves NimCache) compared to a full process restart.
- **Crash recovery with backoff**: restarts use exponential backoff (1s, 2s, 4s, …, capped at 30s). After `MAX_CRASH_RETRIES`, the user is notified and the dead slot is removed from the pool so the next `didOpenFile` starts fresh.

### Reduction of async surface

A significant source of bugs in the original was async procs that did not strictly need to be async. Under Chronos's cooperative scheduler, sync procs are implicitly atomic — nothing else can run between two statements. The rewrite de-asynced many procs that only performed table mutations or queue enqueue operations, making their atomicity explicit rather than relying on correct placement of `await` points.

Infinite-loop coroutines use `while true` + `await sleepAsync(...)`, never tail recursion. Each tail-recursive call in Nim async creates a new closure-backed `Future` that is not freed until the entire chain resolves — for an infinite loop, that is never — leading to unbounded heap growth.

---

## Measured Improvements

All figures from instrumented LSP trace logs:

| Metric | Before | After |
|--------|--------|-------|
| VS Code startup (Dock launch, wrong nimble binary) | 1+ minute | addressed in extension separately |
| `nimble dump` | tens of seconds (SAT UNSAT) | 1–4 seconds |
| Nimsuggest cold-compile (empty NimCache) | ~53 seconds | ~11 seconds |
| `extension/tasks` (NimScript compile) | ~13 seconds | ~1 second |
| Server crashes per session | frequent (SIGSEGV loop) | zero |

The cold-compile reduction from 53s to 11s is the direct effect of `nimble.paths` forwarding. The remaining 11 seconds is pure Nim compiler parse and type-check time for the project's import tree — unavoidable for a cold start. Subsequent requests are fast (< 1 second) because nimsuggest caches the compiled AST in NimCache on disk, which persists between VS Code sessions.

---

## Requirements

- `nimble >= 0.16.1`
- A `nimsuggest` built with `--v4` support (Nim 1.6+ or devel)
- Run `nimble setup` in your project root to generate `nimble.paths` (see Best Practices above)
