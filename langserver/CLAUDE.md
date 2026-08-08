# CLAUDE.md — nimlangserver fork context

IMPORTANT: Never connect to an MCP server!! 

This is a fork of [nimlangserver](https://github.com/nim-lang/langserver). The primary
goal is to fix severe startup performance problems caused by nimble's exponential SAT
solver running during VS Code startup.

## Branch structure

Work is split across stacked branches (each builds on the previous):

| Branch | PR target | Content |
|--------|-----------|---------|
| `fix/maxnimsuggestlimits-clean` | upstream `master` | Fixes 7–10 below |
| `fix/nimsuggest-rename-recompile` | `fix/maxnimsuggestlimits-clean` | Fixes 11–21 below |

When `fix/maxnimsuggestlimits-clean` merges, rebase `fix/nimsuggest-rename-recompile`
onto upstream `master` and update its PR base.

---

## The Core Problem: nimble SAT solver on startup

**Symptom**: Opening VS Code takes 1+ minute before language features (hints, hover,
completions) become usable. During this time, `nimble` is at 100% CPU.

**Root cause**: `nimble dump` internally runs a package constraint solver. When nimble
cannot satisfy the `requires nim >= X.Y.Z` constraint from its package database, the
solver returns UNSAT and invokes `findMinimalFailingSet` — an exponential-time UNSAT
prover.

**Call stack observed in sampling** (via macOS `sample`):
```
dump__nimble_u22655
  getNimDir__nimble_u368
    solvePkgs__nimble_u371
      resolveAndConfigureNim__nimblepkgZvnext_u9607
        resolveNim__nimblepkgZvnext_u4540
          solvePackagesWithSystemNimFallback__nimblepkgZvnext_u4453
            solvePackages__nimblepkgZnimblesat_u46596
              getSolvedPackages__nimblepkgZnimblesat_u15412
                solve__nimblepkgZnimblesat_u11806
                  findMinimalFailingSet__nimblepkgZnimblesat_u8852
```

**How nimble derives `nimDir`**: Before producing any output, `nimble dump` calls
`getNimDir` internally to decide which nim compiler to use for the dump itself. This
runs the SAT solver on the `.nimble` file's `requires nim >= X.Y.Z` constraint. If
nimble cannot find a satisfying nim version in `~/.nimble/pkgs2` (e.g. because the
wrong nimble binary is used, or nim is installed via choosenim rather than nimble's own
package database), the solver returns UNSAT and the exponential `findMinimalFailingSet`
runs before any output is produced.

**Key diagnostic**: `Parent Process: Code Helper (Plugin)` in the sample output
(confirmed via `sudo sample $(pgrep nimble) 30`). This identified the caller as the
VS Code extension host, not the langserver process. See the VS Code extension section
below.

---

## Key environmental facts discovered through trace analysis

- **`$HOME` is NOT overridden** by VS Code on this machine (HOME=/Users/dp is always
  correct). The "VS Code overrides $HOME" issue described in older issues does not apply
  here and the `getpwuid`-based fix is not needed.

- **Two nimble binaries exist**:
  - `~/.nimble/bin/nimble` — v0.22.2 (user-installed, correct)
  - `/usr/local/bin/nimble` — v0.18.2 (Homebrew, older)
  - When VS Code is **launched from the Dock**, its PATH is limited (no `~/.nimble/bin`),
    so the langserver finds `/usr/local/bin/nimble` via `{UsePath}`. When launched
    **from the terminal**, the full shell PATH is inherited and the right binary is used.
  - The slow nimble runs had nimble's **parent process as `Code Helper (Plugin)`**
    (confirmed via `sudo sample $(pgrep nimble) 30`). Initial assumption was that this
    came from `getNimbleDumpInfo` in the langserver. **This was wrong.** `Code Helper
    (Plugin)` is the VS Code extension host — the Node.js process running the vscode-nim
    extension. The call came from `setNimDir` in `src/nimvscode.nim`, not from the Nim
    langserver at all. See the VS Code extension section below.

- **`nimble.paths` is gitignored** by design. Users must run `nimble setup` in the
  project root to generate it. Without it, nimsuggest's Nim compiler has no `--path:`
  information and must call nimble to resolve every import.

- **`nimble setup`** is the canonical mechanism for resolving packages without the SAT
  solver at runtime. It generates `nimble.paths` containing `--noNimblePath` + one
  `--path:` entry per dependency. `config.nims` auto-includes this file.
  Running `nimble setup` fixed the langserver's broken imports (chronicles, chronos, stew
  showing "cannot open file") immediately.

- **The cold-compilation gap is ~11 seconds with `nimble.paths` forwarded, not 53.**
  An earlier experiment concluded the 53-second gap was pure Nim compiler cold-start
  time and that passing `--noNimblePath` made no difference. That experiment predates
  fix #10 (`nimble.paths` forwarding). Traces 13 and 14 (collected after fix #10, with
  the correct `~/.nimble/bin/nimble` on PATH) show the `user_interfaces` sub-module
  cold-compiling in **~11 seconds** from a fully empty NimCache — confirmed independently
  by a pending hover request self-reporting `"11 seconds, 168 milliseconds"` at the
  moment nimsuggest became ready. The most likely explanation is that nimsuggest's
  internal Nim compiler was still invoking nimble for some path resolution in the earlier
  test despite `--noNimblePath` being passed, and the properly-constructed `nimble.paths`
  forwarding via `findNimblePaths` eliminated that overhead. The per-subpackage
  `config.nims` files (which add `--path:` for intra-monorepo deps) are also loaded
  correctly when `workingDir` is set to the project root. Subsequent requests remain
  fast (< 1 second) because nimsuggest caches the compiled AST in NimCache on disk.

---

## What was fixed (this branch)

### 7. `workspace/didRenameFiles` — hints broken after moving files (commit `ce669b4`)

**Files**: `protocol/types.nim`, `nimlangserver.nim`, `routes/lsp.nim`, `ls.nim`

**Problem**: Moving a `.nim` file between folders in VS Code breaks hover/hints/
completions in the new location. No handler for `workspace/didRenameFiles` existed.

**Fix**:
- Added `FileRename` and `RenameFilesParams` types to `protocol/types.nim`.
- Uncommented `fileOperations*` field in `ServerCapabilities_workspace`.
- Advertised `didRename` capability for `**/*.nim` in the `initialize` response.
- Registered `workspace/didRenameFiles` route in `nimlangserver.nim`.
- Implemented `didRenameFile` in `ls.nim`: moves the stash file, invalidates
  `nimDumpCache` if a `.nimble` was renamed, migrates the `openFiles` entry,
  and starts nimsuggest for the new project if the file crossed a project boundary.
- Added early-return guard in `didCloseFile` and `didOpenFile` to prevent
  KeyError / double-insertion after a rename.

**Limitation fixed in #11**: this handler did not tell nimsuggest to rebuild its
module graph after a same-project rename, causing SIGSEGV on the next `sug` request.

### 8. Config-first nimsuggest initialisation (commit `8d027f9`)

**Files**: `ls.nim`, `routes/lsp.nim`

**Problem**: Nimsuggest spawned before VS Code config arrived, so `projectMapping` and
`maxNimsuggestProcesses` were always empty/default at spawn time.

**Fix**:
- Added `waitForWorkspaceConfiguration()` proc: polls `ls.workspaceConfiguration`
  every 50ms, up to 30s, then falls back to defaults. Does NOT cancel the shared future.
- Moved `initNimsuggestInstances` from `initialize` to `initialized` handler, after
  the config wait.
- In `didOpenFile`: `waitForWorkspaceConfiguration()` is called **before**
  `getProjectFile()` so `projectMapping` regex matching uses real config.

### 9. Debug logging at nimble call sites (commit `6703b84`)

**Files**: `ls.nim`, `routes/lsp.nim`

Added `HOME`, `PATH`, `NIMBLE_DIR` logging before every nimble invocation so traces
reveal exactly which binary is found and whether the environment is correct.

### 10. Pass `nimble.paths` flags to nimsuggest (commit `7658a79`)

**Files**: `ls.nim`, `suggestapi.nim`

**Problem**: Nimsuggest spawned without `--path:` flags, so its Nim compiler had to call
nimble internally to resolve every import — either hitting the SAT solver (for local
packages not in pkgs2) or failing to find packages entirely (for users without
`nimble.paths`).

**Fix**:
- `findNimblePaths(fromFile)` in `ls.nim`: walks up the directory tree from the project
  file to find the nearest `nimble.paths`, parses it, strips quotes from `--path:"..."`,
  and returns clean args.
- `createOrRestartNimsuggest` calls `findNimblePaths` and logs `nimPathCount=`.
- `createNimsuggest` in `suggestapi.nim` gains `nimPaths: seq[string] = @[]` parameter;
  entries are appended to nimsuggest's arg list before spawn.
- `startProcess` for nimsuggest now passes `workingDir = workingDir` so the Nim compiler
  searches for `config.nims` from the project root.

**Result**: Nimsuggest now receives `--noNimblePath --path:...` at startup. The Nim
compiler inside it resolves imports directly without calling nimble. This fixes broken
imports for users who have run `nimble setup`. Cold-compilation time dropped from the
previously measured ~53 seconds to ~11 seconds (see measured performance section).

**Note on `--noNimblePath`**: we do not explicitly pass this flag. `findNimblePaths`
reads `nimble.paths` verbatim and passes every line to nimsuggest. `--noNimblePath`
is the first line of that file (put there by `nimble setup`) and hits the `else`
branch in `findNimblePaths`, so it is forwarded unchanged. Passing it is correct:
nimsuggest's internal Nim compiler should not call out to nimble at runtime. The
per-subpackage `config.nims` files (see funis project context) also set `--noNimblePath`
via `include "nimble.paths"`, so the flag arrives twice but that is harmless.

### 11. Trigger nimsuggest recompile after `.nim` file rename (commit `b478ab0`)

**Files**: `ls.nim`

**Problem**: After a `.nim` file rename, nimsuggest's module graph still references
the old filename. The next `sug` (autocomplete) request calls `recompilePartially`,
which fails because the old file no longer exists. Both internal fallback recompiles
(`compileProject` then `recompileFullProject`) fail silently and are caught. With no
module registered in the graph, `getModule(fileIndex)` returns nil. The nil dereference
at `nimsuggest.nim:1156` (`incl m.flags, sfDirty`) crashes nimsuggest with SIGSEGV.

The crash manifests as `ERR NimSuggest Error (stderr) err="SIGSEGV: Illegal storage
access. (Attempt to read from nil?)"` in the LSP trace, always on a `sug` command.
The `projectErrors` list in `extension/statusUpdate` is misleading — it shows the
commands that failed *because* the socket was already closed, not the command that
caused the crash.

**Fix**:
- In `didRenameFile`, after migrating the `openFiles` entry, check if the renamed
  file is a `.nim` and the old project has a running nimsuggest instance.
- If so, call `traceAsyncErrors ns.recompile()` — this sends the `recompile` command
  to the live nimsuggest process, triggering `recompileFullProject()` in-process.
- Cheaper than a process restart: the warm nimsuggest process and its NimCache are
  preserved; only the module graph is rebuilt.
- `Nimsuggest.recompile()` was already generated by `createGlobalCommand(recompile)`
  in `suggestapi.nim` — no new proc needed.

### 12. openFiles state drift and permanent crash blocking (commits `cd831c1`, `9dee432`, `6efa44a`)

**Files**: `ls.nim`, `routes/lsp.nim`

**Diagnosed from**: `error_trace4.txt`, `error_trace5.txt`

#### Bug A: `ns.openFiles` diverges from `ls.openFiles` after file close

`ls.openFiles` (LSP ground truth) and `ns.openFiles` (per-nimsuggest tracking set) are
architecturally separate: there can be multiple nimsuggest instances each owning a subset
of open files, and the nimsuggest protocol has no "close" command. `ns.openFiles` is
populated at open time (`ns.openFiles.incl(uri)` in `didOpenFile`) but was never cleared
at close time. `didCloseFile` only did `ls.openFiles.del(uri)`.

**Consequence**: stale entries in `ns.openFiles` caused `cancelPendingFileChecks`
to call `ls.openFiles[uri]` on a key that no longer exists, raising `KeyError`
(since `NlsFileInfo` is a `ref` and `Table.[]` throws for missing keys,
not returns nil — the `if fileData != nil:` guard on the next line was ineffective).

**Fix** (`cd831c1`):
- `didCloseFile`: after `ls.openFiles.del uri`, iterate `ls.projectFiles` and call
  `project.ns.read().openFiles.excl(uri)` on each finished nimsuggest.
- `cancelPendingFileChecks`: changed `ls.openFiles[uri]` to `ls.openFiles.getOrDefault(uri)`
  as a belt-and-suspenders guard for any remaining window between the two operations.
- `didOpenFile`: removed dead `elif ls.projectFiles.len > 0 and uri in ls.openFiles:`
  block that attempted to overwrite `openFiles[uri].projectFile`; `getProjectFile`
  already handles reuse internally and returns the reused project directly, so this
  branch was never reached.

#### Bug B: `checkFile` in re-registration loop caused hover regression

The post-restart re-registration loop (after a nimsuggest crash/restart) called
`traceAsyncErrors ls.checkFile(openUri)` for each re-registered file. This sent
a `changed` command to the fresh nimsuggest for files not yet in its module graph,
triggering `unknownFile` compilation with incompatible import paths and corrupting
module context. Hover and inlay hints broke for the session.

**Fix** (`9dee432`):
- Removed `checkFile` calls from the re-registration loop entirely. Nimsuggest
  rebuilds its module graph after restart without needing explicit file-check nudges.
- Crash-inducing files (those in `crashedFiles`) are now skipped during re-registration
  so they are not added to `newNs.openFiles`, preventing the `tryGetNimsuggest` guard
  from being bypassed on the next request.

#### Bug C: `crashedFiles` never cleared — permanent blocking for the session

`crashedFiles: Table[string, HashSet[string]]` was only ever added to (in
`onErrorCallback`) and never cleared. The "Restart nimsuggest" button did not clear it.
`didSave` called `tryGetNimsuggest` first, which returned `none` for blocked files and
caused an early return — so saving a fixed file did nothing to un-block it. The only
escape was restarting the entire language server process.

**Fix** (`6efa44a`):
- `didSave`: un-block the file from `crashedFiles` **before** calling `tryGetNimsuggest`,
  so a save always attempts recovery.
- `restart` template in `routes/lsp.nim`: `ls.crashedFiles.del(projectFile)` — an
  explicit "Restart nimsuggest" is a user signal to start fresh; all blocked files
  for that project are cleared immediately.
- Added `sets` import to `routes/lsp.nim` (required for `HashSet` `excl`/`del` ops).

### 13. "Latest file wins" restart — cross-project unknownFile without SIGSEGV (commits `1dbca3e`, `147d0fd`)

**Files**: `ls.nim`

**Diagnosed from**: `error_trace9.txt`, `error_trace10.txt`, `error_trace11.txt`

#### The problem

With `maxNimsuggestProcesses=1`, whichever project opens first claims the nimsuggest
slot. When a subsequent file belongs to a consumer project (higher in the dependency
tree), `getProjectFile` falls back to reusing the existing nimsuggest. If that file is
not in the running nimsuggest's module graph, the `unknownFile` capability compiles it
on-the-fly — but with incompatible `--path:` flags → SIGSEGV at `nimsuggest.nim:1156`.

**Why the SIGSEGV only fires for `sug`/`con`**: The crash at `nimsuggest.nim:1156`
(`incl m.flags, sfDirty`) is in the `ideSug`/`ideCon` branch only. Hover (`highlight`)
and inlay hints take a different code path that has a nil guard. So blocking ALL commands
(as an earlier `knownToNimsuggest`/`isReusedProject` guard attempted) was wrong — it
broke hover for cross-project files when no crash would have occurred.

**Why nimsuggest doesn't see the whole monorepo**: Nimsuggest follows `import`
statements from its entry point only. A dependency-level project (`user_interfaces_shared`)
cannot see consumer-level files (`user_interfaces`, `liszt`) because imports are
one-directional. Starting nimsuggest for the dependency-level project means all
consumer-level files are "unknown" to it.

#### Fix — "latest file wins" restart (`1dbca3e`)

When `warnIfUnknown` detects `isKnown=false` and the assigned project differs from what
`projectMapping` intended (reuse was forced), restart nimsuggest for the intended project:

1. **`getIntendedProjectFile(fileUri, ls)`** — new proc that performs only the
   `projectMapping` regex lookup without the reuse fallback, returning the project the
   mapping intended (or `""` if no mapping matches). Forward-declared alongside
   `getProjectFile`.

2. **`warnIfUnknown`** gains `intendedProjectFile: string = ""` parameter. On
   `isKnown=false` with `intendedProjectFile != "" and intendedProjectFile != projectFile`:
   - Guard: if the intended project already has a running nimsuggest, skip (no thrash).
   - Clear `errorCallback` on the old project before stopping (see fix 14 / `147d0fd`).
   - Stop the old nimsuggest, call `createOrRestartNimsuggest(intendedProjectFile, uri)`.
   - Redirect the old slot: `ls.projectFiles[projectFile] = ls.projectFiles[intendedProjectFile]`
     so files whose `projectFile` future already resolved to the old key still find a
     working nimsuggest.
   - Reassign all open files: iterate `ls.openFiles.mpairs`, replace finished futures
     pointing to `projectFile` with new futures for `intendedProjectFile`, so the
     re-registration loop includes them.

3. **`didOpenFile`** calls `getIntendedProjectFile(uriToPath(uri), ls)` after resolving
   `projectFile`, then passes the result through to `warnIfUnknown`.

#### Fix — clear `errorCallback` before intentional stop (`147d0fd`)

**Diagnosed from**: `error_trace11.txt`

When `warnIfUnknown` stopped the old nimsuggest, any in-flight command (e.g. `outline`
for `documentSymbol`) triggered `onErrorCallback` when the process was killed. This:
1. Wrote a spurious crash block: `crashedFiles[oldProject].incl(file)` — permanently
   blocking the file under the old project key before the reassignment loop could redirect it.
2. Auto-restarted the old nimsuggest via `autoRestart`, fighting against the intended restart.

**Fix**: before `project.stop()`, set `project.errorCallback = none(ProjectCallback)`.
This matches the pattern already used in the `restart` template in `routes/lsp.nim`.
With the callback cleared, the process death on a pending command is silently ignored.

**Invariant**: always clear `errorCallback` before any intentional `project.stop()`.
The `restart` template and `warnIfUnknown` now both do this. Any future code that
stops a nimsuggest intentionally must follow the same pattern.

### 14. `removeIdleNimsuggests` — OrderedSet mutation during iteration (ls.nim:1626)

**Files**: `ls.nim`

**Diagnosed from**: `error_trace13.txt`

**Problem**: The server crashed with exit code 1 after ~3 minutes of use:

```
ERR Error in main
sets.nim(908, 11) `len(s) == length` the length of the OrderedSet changed while iterating over it
ls.nim(1635)  removeIdleNimsuggests
```

The log sequence immediately before the crash:
1. `Removing idle nimsuggest project=user_interfaces.nim` — `removeIdleNimsuggests` begins iterating `ns.openFiles`
2. `Removing idle nimsuggest open file uri=…/midi_input_ui.nim` — mid-iteration
3. `Closed the following document uri=…/midi_input_ui.nim` — `didCloseFile` fires at an `await` point
4. `[chg:didCloseFile] removing closed file from ns.openFiles` — `project.ns.read().openFiles.excl(uri)` called
5. **CRASH** — `OrderedSet` modified during active iteration

The root cause: `removeIdleNimsuggests` iterates `ns.openFiles` (an `OrderedSet[string]`)
in a `for` loop that contains `await` points (`await ls.makeIdleFile`). At each `await`,
the Chronos event loop can yield to other tasks. The `didCloseFile` handler (fix `cd831c1`)
calls `project.ns.read().openFiles.excl(uri)`, modifying the same set mid-iteration. Nim's
`OrderedSet` iterator asserts `len(s) == length` at each step, detecting the mutation and
raising a fatal exception.

**Fix**: Snapshot `ns.openFiles` into a `seq` before the loop:

```nim
# ls.nim:1626 — before
for uri in ns.openFiles:

# after
for uri in ns.openFiles.toSeq:
```

`toSeq` (from `std/sequtils`, already imported) eagerly copies all elements into a new
`seq[string]` before the loop body starts. Subsequent modifications to `ns.openFiles`
via `excl` cannot affect the seq iterator. No other changes needed.

**Verified**: `error_trace14.txt` (collected after this fix) ran the full session with
zero crashes and `"projectErrors": []` at close.

### 15. Langserver SIGSEGV on Dock launch — nil `process` in `getNimbleDumpInfo` finally block (ls.nim)

**Files**: `ls.nim`

**Diagnosed from**: `error_trace18.txt`

**Problem**: When VS Code is launched from the Dock, PATH is restricted to
`/usr/bin:/bin:/usr/sbin:/sbin` — nimble is not on it. The langserver crashed with
SIGSEGV 5 times in rapid succession, then VS Code gave up and stopped restarting it.

The crash happened in the **langserver process itself** (not nimsuggest), within
milliseconds of the `initialized` handler firing. The last log lines before each SIGSEGV:

```
DBG getNimbleDumpInfo environment  nimbleFile=... PATH=/usr/bin:/bin:/usr/sbin:/sbin
SIGSEGV: Illegal storage access. (Attempt to read from nil?)
```

**Root cause**: In `getNimbleDumpInfo`:

```nim
var process: AsyncProcessRef          # starts as nil
try:
  process = await startProcess("nimble", ...)   # OSError: not found on PATH
  ...
except OSError, IOError:
  debug "Failed to get nimble dump info", ...
finally:
  await shutdownChildProcess(process)  # called with process = nil → SIGSEGV
```

`startProcess` threw `OSError` (nimble not found), so `process` was never assigned.
The `finally` block ran unconditionally and called `shutdownChildProcess(nil)`.
`shutdownChildProcess` immediately calls `p.processID()` on the nil ref → SIGSEGV.
VS Code auto-restarted the server, which hit the same path 5 times, then gave up.

**Fix** (`ls.nim`):

```nim
finally:
  if process != nil:
    await shutdownChildProcess(process)
```

**Why Dock vs terminal**: Terminal launch inherits the full shell PATH including
`~/.nimble/bin` → nimble is found → `startProcess` succeeds → `process` is valid.
Dock launch has only `/usr/bin:/bin:/usr/sbin:/sbin` → OSError → `process` stays nil.

**Invariant**: Any `var p: AsyncProcessRef` that may not be assigned (i.e., in a
`try` block where `startProcess` can fail before assignment) must be guarded with
`if p != nil:` before calling `shutdownChildProcess` in the `finally` block.

### 16. Test listing error when `test.entryPoint` is not configured (testrunner.nim)

**Files**: `testrunner.nim`

**Diagnosed from**: `error_trace19.txt` (also reproduces from `error_trace18.txt`)

**Problem**: On every project load, VS Code shows:

```
There was an issue trying to load the tests (see lsp output for more details):
Hint: used config file '...' [Conf]
command line(1, 2) Error: fatal error: command expects a filename
```

The LSP log showed:
```
ERR Failed to list tests  nimPath=... entryPoint= res=1
ERR Command args:  args="@[\"c\", \"--outdir:...\", \"-d:unittest2ListTests\", \"-r\", \"\"]"
```

**Root cause**: When `nim.test.entryPoint` is `""` (the default/unconfigured state),
`listTests` in `testrunner.nim` called `getFullPath("", workspaceRoot)` which returns
`""` (empty string can't be resolved to a file), then passed it directly to
`startProcess("nim", arguments = ["c", "--outdir:...", "-d:unittest2ListTests", "-r", ""])`.
Running `nim c` with an empty filename argument produces "command expects a filename".

`runTests` already had a `if not fileExists(entryPoint): return` guard; `listTests` did not.

**Fix** (`testrunner.nim`):

```nim
var entryPoint = getFullPath(entryPoint, workspaceRoot)
if not fileExists(entryPoint):
  debug "Listing tests: entry point does not exist, skipping", entryPoint = entryPoint
  return TestProjectInfo()
```

Added immediately after `getFullPath`, mirroring the existing guard in `runTests`.

### 17. In-flight nimsuggest commands throw "Server crashed" on `warnIfUnknown` restart (suggestapi.nim)

**Files**: `suggestapi.nim`

**Diagnosed from**: `error_trace19.txt`

**Problem**: When the user switches to a file belonging to a different project (triggering
`warnIfUnknown` to restart nimsuggest), VS Code showed a "documentSymbol Missing" error
in the outline panel.

**Sequence**:
1. User opens `model/api/src/api/crud/api_products.nim`
2. VS Code sends `textDocument/documentSymbol` immediately
3. The langserver sends `outline api_products.nim` to the running `user_interfaces` nimsuggest
4. Concurrently, `warnIfUnknown` detects `isKnown=false` and kills `user_interfaces`
   nimsuggest, starting a new one for `api.nim` (the intended project)
5. The in-flight `outline` TCP connection closes; `processQueue` reads empty content
6. `suggestapi.nim` calls `req.future.fail newException(CatchableError, "Server crashed/socket closed.")`
7. `documentSymbols` in `routes/lsp.nim` had no `try/except` → exception propagated to
   `runRpc` → LSP error response sent to VS Code → user-visible error notification

**Why only `documentSymbol`**: By the time `inlayHint` ran, `project.failed` was already
`true` from step 6, so it hit the early-return-empty path at line 446–448 of suggestapi.nim.
`documentSymbol` was the first request, so it raced with the kill.

**Why not just add `try/except` in `documentSymbols`**: The same race can hit any
command handler (`hover`, `completion`, `definition`, `references`, etc.) whenever
`warnIfUnknown` fires. Adding individual guards to every handler is fragile.

**Fix** (`suggestapi.nim`): Remove the `req.future.fail` call when content is empty.
Let `res` (which is `@[]`) fall through to `req.future.complete res`:

```nim
# Before:
if (content == ""):
  self.project.markFailed "Server crashed/socket closed."
  debug "Server socket closed"
  if not req.future.finished:
    debug "Call cancelled before sending error", command = req.command
    req.future.fail newException(CatchableError, "Server crashed/socket closed.")

# After:
if (content == ""):
  self.project.markFailed "Server crashed/socket closed."
  debug "Server socket closed"
```

**Why this is safe**: Crash detection and auto-restart are driven by
`markFailed` → `errorCallback`, not by the future's fail/complete state.
`markFailed` is still called; `errorCallback` still triggers `createOrRestartNimsuggest`
for genuine crashes. Intentional stops already clear `errorCallback` before `stop()`
(the invariant from fix #13/#14), so those don't trigger spurious restarts.
In-flight commands now complete with `@[]` instead of throwing — all callers get
empty results transiently rather than user-visible error notifications.

### 18. IDE features for files not yet imported into the project (ls.nim, suggestapi.nim)

**Files**: `ls.nim`, `suggestapi.nim`

**Diagnosed from**: `error_trace23.txt`, `error_trace24.txt`, `error_trace25.txt`, `error_trace26.txt`

#### The problem

When a file matches a `projectMapping` regex (e.g. `fraction_layouts.nim` matching
`controller/user_interfaces/(src|tests)/.*\.nim`) but is not transitively imported by the
project entry point (`user_interfaces.nim`), nimsuggest's `known` command returns `false`
for it. The langserver's `warnIfUnknown` function detected this and — via an uncommitted
working-tree `else` branch — showed a blocking warning:

```
fraction_layouts.nim is not imported by user_interfaces.nim and cannot be resolved in
isolation. IDE features (hover, goto-definition, inlay hints) will be unavailable.
```

This broke the legitimate use case of writing a new file in isolation before adding it
to the project's import tree.

#### Why the `unknownFile` capability doesn't help here

Nimsuggest advertises `unknownFile` capability, but this capability behaves differently
between protocol versions:

- **v3 (`executeNoHooks`)**: checks the `isKnownFile` output of `fileInfoIdx` and calls
  `graph.compileProject(dirtyIdx)` unconditionally for unknown files, before any
  command-specific logic. Unknown files ARE compiled standalone regardless of command.

- **v4 (`executeNoHooksV3`)**: calls `graph.needsCompilation(fileIndex)` as a gate before
  `recompilePartially`. For a file with no module in the graph, `getModule(fileIndex)`
  returns nil → `needsCompilation` returns `false` → `recompilePartially` is never called
  → all position commands (`highlight`, `def`, `outline`, etc.) return `length=0`.

The langserver always starts nimsuggest with `--v4`, so the v3 standalone-compilation
path is never taken. The `unknownFile` capability is effectively non-functional for truly
unknown files in v4 mode.

#### Fix (initial)

In `warnIfUnknown`'s `else` branch (when `canHandleUnknown=true`, `isKnown=false`, and
`intendedProjectFile == projectFile`), restart nimsuggest with the open file itself as
the entry point. This is the same "latest file wins" pattern used for cross-project
unknown files:

- Clear `errorCallback` before stopping (the invariant from fix #13).
- Stop the old nimsuggest, call `createOrRestartNimsuggest(path, uri)`.
- Redirect `ls.projectFiles[projectFile] = ls.projectFiles[path]` so files already
  assigned to the old key still find a working nimsuggest.
- Reassign all open files to `path` so the re-registration loop includes them.

After this, nimsuggest compiles `fraction_layouts.nim` as its entry point using the
project's `--path:` flags and `config.nims`. All IDE features become available for that
file. Features for `user_interfaces.nim` are transiently unavailable (same tradeoff as
"latest file wins"); opening `user_interfaces.nim` would trigger another restart.

#### Cascade bug (diagnosed from `error_trace25.txt`, `error_trace26.txt`)

**Problem**: With multiple open files all unimported by the project, the initial standalone
restart triggered a cascade: after `fraction_layouts.nim` standalone started, `proportion_tree_left.nim`
(also open, also unimported, assigned to the same project) had its `warnIfUnknown` fire
against the fraction_layouts nimsuggest, which returned `isKnown=false`, triggering yet
another standalone restart — which in turn kicked out fraction_layouts. The result was
sequential per-file restarts (each 8–11 seconds), with the nimsuggest slot constantly
changing hands and no file ever maintaining stable IDE features.

**Root cause in two parts**:

*Part A — cascade*: The reassignment loop in the standalone branch sets ALL open files'
`projectFile` to `path` (the standalone file). This causes `proportion_tree_left.nim`'s
`tryGetNimsuggest` to resolve to the standalone nimsuggest when it starts. That
nimsuggest doesn't know `proportion_tree_left.nim` → `warnIfUnknown` fires → another
standalone restart.

*Part B — incorrect guard bypass after redirect*: The guards in both the cross-project
branch and the standalone branch checked `existingNs.finished and not existingNs.failed`.
After a redirect (`ls.projectFiles[A] = ls.projectFiles[B]`), the entry at key `A` points
to a Project whose `.file` is `B`. This is a redirect alias, not a real running instance
for `A`. The guard couldn't distinguish them and incorrectly skipped needed restarts.

**Fix — cascade prevention** (now only in the "kill and replace" path, after fix #19):

```nim
if projectFile in ls.projectFiles:
  let projEntry = ls.projectFiles[projectFile]
  if projEntry.file != projectFile and path != projectFile:
    debug "cascade prevention — standalone restart already active for another file"
    return
```

If `projEntry.file != projectFile`, the slot is a redirect alias from an ongoing "kill and
replace" standalone restart for a different file. If the current file is also not the project
entry-file itself (`path != projectFile`), it would cause a cascade — skip it. Only the project
entry-file (where `path == projectFile`) is allowed past this check, as that represents a
deliberate "latest file wins" focus switch.

Note: with `maxNimsuggestProcesses > 1`, the "spawn alongside" path is taken instead of
"kill and replace", so no redirect aliases are created and cascade prevention is not reached.

**Fix — redirect alias detection** (both guards, cross-project and standalone):

Both guards were changed from:
```nim
if existingNs.finished and not existingNs.failed:
  return  # skip
```
to:
```nim
if existingProj.file == expectedFile and  # ← new: must match the key, not a redirect
    existingProj.ns.finished and not existingProj.ns.failed:
  return  # skip
```

Where `expectedFile` is `intendedProjectFile` (cross-project branch) or `path` (standalone
branch). A redirect alias has `.file` pointing to a different project, so the check fails
and the guard doesn't fire, allowing the restart to proceed.

**Timing subtlety**: `createOrRestartNimsuggest` is synchronous (uses `waitFor`), blocking
the event loop for the full cold-compile time (~8–11 seconds). The redirect
(`ls.projectFiles[projectFile] = ls.projectFiles[path]`) is applied AFTER this blocking
call returns. During the blocking period, other coroutines run (Chronos spins the event
loop inside `waitFor`). This means:

- `warnIfUnknown` for `user_interfaces.nim` fires WHILE `fraction_layouts.nim` is
  compiling (during the 8-second wait). At that moment, `ls.projectFiles["user_interfaces.nim"]`
  still holds the original stopped project (`.file="user_interfaces.nim"`, `ns.finished=true`).
  The redirect-alias check correctly identifies this as the ORIGINAL project entry (not a
  redirect), and the existing "already running" guard fires. This is **intentionally correct**:
  starting a second nimsuggest while one is already compiling would create two concurrent
  11-second compiles, violating `maxNimsuggestProcesses=1`. The file stays broken until
  the user re-focuses it (which triggers a fresh `warnIfUnknown` after the redirect is in place).
- After the redirect is applied, a second `warnIfUnknown` for `user_interfaces.nim` (from
  a re-focus or tab switch) correctly sees `.file="fraction_layouts.nim" ≠ "user_interfaces.nim"`
  → redirect-alias check fails → guard doesn't fire → standalone restart for user_interfaces.nim.

#### Cleanup: `mod` proc removed from suggestapi.nim

The `mod` proc in `suggestapi.nim` sent the command string `"ideMod"` to nimsuggest,
but nimsuggest's parser expects `"mod"` (maps `of "mod": conf.ideCmd = ideMod`). The
wrong string `"idemod"` falls to `else: err()` in the parser (prints help) for all
protocol versions — the proc never worked. It had zero callers in the current codebase
(`checkFile` already uses `changed` + `chkFile`, not `mod`). Removed as dead code.

### 19. Multi-nimsuggest support — spawn alongside + LRU replacement (commit `1643bdc`)

**Files**: `ls.nim`

**Problem**: With `maxNimsuggestProcesses=1` the standalone branch always killed the
existing nimsuggest and replaced it ("latest file wins"). With a split-screen of two
unimported files (`fraction_layouts.nim`, `proportion_tree_left.nim`) this caused constant
thrashing — each file's `warnIfUnknown` fired and killed the other's nimsuggest. Neither
file ever had stable IDE features.

With `maxNimsuggestProcesses=2` a second slot is available; the langserver should spawn
a second nimsuggest alongside the first rather than replacing it.

Additionally, all three places that needed to pick an existing nimsuggest when the
limit was hit used `ls.projectFiles.keys.toSeq[0]` — an arbitrary choice. The correct
policy is Least Recently Used (lowest `lastCmdDate`).

#### Fix — `leastRecentlyUsedProjectFile` helper

New sync proc added before `warnIfUnknown`:

```nim
proc leastRecentlyUsedProjectFile(ls: LanguageServer): string =
  var oldest = now()
  result = ls.projectFiles.keys.toSeq[0]
  for k, proj in ls.projectFiles.pairs:
    if not proj.ns.finished or proj.ns.failed: continue
    let date = proj.lastCmdDate.get(dateTime(1970, mJan, 1, 0, 0, 0, 0, utc()))
    if date < oldest:
      oldest = date
      result = k
```

Uses `Project.lastCmdDate` (already updated by `processQueue` after every command).
Falls back to the first key if no finished instance exists (all still compiling).

Replaces `keys.toSeq[0]` in:
- `getProjectFile` (both reuse paths — mapping match and auto-guess)
- `getNimsuggestInner` failTable fallback

#### Fix — `warnIfUnknown` standalone branch split

The `else:` branch (canHandleUnknown=true, isKnown=false, intendedProjectFile==projectFile)
now forks on `canSpawn = await ls.shouldSpawnNimsuggest()`:

**"Spawn alongside" path (`if canSpawn`)**: a free slot is available.
1. Reassign `ls.openFiles[uri].projectFile` future to `path` **BEFORE** calling
   `createOrRestartNimsuggest`. This is critical: the addCallback re-registration loop
   inside `createOrRestartNimsuggest` filters on `fileInfo.projectFile.read() == path`;
   the reassignment must be in place before that callback fires.
2. Remove `uri` from the old nimsuggest's `openFiles` (it now has its own instance).
3. Call `createOrRestartNimsuggest(path, uri)` — starts new nimsuggest, does NOT stop
   the existing one.
4. No redirect alias created. No reassignment of other open files. The old nimsuggest
   continues serving all files it already tracks.

**"Kill and replace" path (`else`)**: at the process limit.
- Cascade prevention guard lives **only here** (redirect aliases only exist in this path).
- Clear `errorCallback`, stop old nimsuggest, start new one, create redirect alias,
  reassign all open files pointing to the old project. Same logic as before fix #19.

#### Fix — `restartAllNimsuggestInstances` key snapshot

```nim
# Before:
for projectFile in ls.projectFiles.keys:

# After:
for projectFile in ls.projectFiles.keys.toSeq:
```

`createOrRestartNimsuggest` creates a sentinel in `ls.projectFiles` before the first
`await`, mutating the table. Iterating the live table while it mutates causes a crash
or skipped entries.

#### Fix — `shouldSpawnNimsuggest` and `leastRecentlyUsedProjectFile` placement

Both procs moved to **before** `warnIfUnknown` in the file. No forward declaration
needed. (`shouldSpawnNimsuggest` was previously defined after `warnIfUnknown`, which
caused an "undeclared routine" error when `warnIfUnknown` tried to call it.)

#### Fix — `getLspStatus` port deduplication

`getLspStatus` now tracks `seenPorts: HashSet[int]` and skips nimsuggest instances
whose port has already been reported. This eliminates duplicate entries in
`extension/statusUpdate` caused by redirect aliases (where two keys in `ls.projectFiles`
point to the same `Project`/`Nimsuggest` object with the same port).

#### Fix — `removeIdleNimsuggests` redirect alias cleanup

When stopping an idle nimsuggest, `project.file` alone was used to delete from
`ls.projectFiles`. Redirect aliases (keys where `key ≠ project.file`) were never
deleted, accumulating indefinitely. Fixed by iterating all keys and deleting any
whose `project.file` matches the stopped project:

```nim
let fileToStop = project.file
for k in ls.projectFiles.keys.toSeq:
  if ls.projectFiles.hasKey(k) and ls.projectFiles[k].file == fileToStop:
    ls.projectFiles.del(k)
```

Also added `seenFiles: HashSet[string]` deduplication so the same project is not
processed twice (redirect aliases share the same `project.file`).

#### Fix — `workspace/didDeleteFiles` handler

New handler `didDeleteFile` in `ls.nim`:
- Invalidates `nimDumpCache` if a `.nimble` was deleted.
- Syncs `ns.openFiles` on all live nimsuggest instances (excl the deleted uri).
- Triggers `recompile` on all live instances for deleted `.nim` files.

Wired up in `protocol/types.nim` (`FileDelete`, `DeleteFilesParams` types),
`routes/lsp.nim` (`didDeleteFiles` proc + `didDelete` capability in `initialize`),
and `nimlangserver.nim` (route registration).

#### Fix — `ListTestsParams.entryPoint` as `Option[string]`

Changed from `string` to `Option[string]` in `protocol/types.nim`. Call sites in
`routes/lsp.nim` use `.get("")`. Eliminates the empty-string sentinel anti-pattern.

#### Fix — JSON-RPC error response in `lstransports.nim`

`runRpc`'s `except CatchableError` block now sends a JSON-RPC error response
(`code: -32603`) to the client. Previously the exception was logged but no response
was sent, causing VS Code to time out waiting for a reply.

### 20. `AsyncProcessError` escapes `getNimbleDumpInfo` — initialized handler aborts (ls.nim:330)

**Files**: `ls.nim`

**Diagnosed from**: `error_trace33.txt`

**Problem**: Chronos's `startProcess` raises `AsyncProcessError` on spawn failure (from
`asyncproc.nim:raiseAsyncProcessError`), NOT `OSError`. The catch clause in
`getNimbleDumpInfo` is:

```nim
except OSError, IOError:
  debug "Failed to get nimble dump info", ...
```

`AsyncProcessError` is not a subtype of `OSError` or `IOError`, so this handler never
fires. The exception propagates uncaught through `initNimsuggestInstances` → `initialized`
handler → `runRpc` (which catches it as `CatchableError`, logs `ERR [RunRPC]`, and drops
it since there is no response ID for a notification).

**Consequence**: the `initialized` handler aborts mid-execution. `ls.entryPoints` is
never set. This happens every time VS Code is launched from the Dock (restricted PATH
`/usr/bin:/bin:/usr/sbin:/sbin` — `nimble` is not on it so `startProcess("nimble")`
raises `AsyncProcessError`). The same escape also occurs from `getProjectFileAutoGuess`,
which calls `getNimbleDumpInfo` for per-directory `.nimble` files during `didOpen`.

**Fix** (`ls.nim:330`):

```nim
# Before:
except OSError, IOError:

# After:
except CatchableError:
```

**Invariant**: never catch `OSError` or `IOError` from async process calls — Chronos
wraps spawn failures in `AsyncProcessError`, not the standard library types. Always use
`except CatchableError` (or specifically `AsyncProcessError`) at async process call sites.

### 21. Failed sentinel blocks re-spawn — `tryGetNimsuggest` spins for 33 seconds per request (ls.nim:1433, 1504)

**Files**: `ls.nim`

**Diagnosed from**: `error_trace33.txt`

**Problem**: When `createOrRestartNimsuggest` fails (e.g. nimsuggest not on PATH), line
1433–1435 has already run synchronously before the first `await`:

```nim
if projectFile notin ls.projectFiles:
  ls.projectFiles[projectFile] =
    Project(file: projectFile, ns: newFuture[Nimsuggest]("pending"))
```

The `except CatchableError` handler at line 1504 logs the error but does NOT complete
or remove this sentinel. The pending future stays pending forever.

Every subsequent `getNimsuggestInner` call:
- `if not ls.projectFiles.hasKey(projectFile):` → FALSE (sentinel is there) → spawn attempt SKIPPED
- Polls `ns.finished` for 10 × 100ms = 1s → always false → returns nil

Then `tryGetNimsuggest` (line 1243) retries 3× with exponential backoff:
- Retry 0: 1s inner wait → nil → sleep 10s
- Retry 1: 1s inner wait → nil → sleep 20s
- Retry 2: 1s inner wait → nil → give up

**Result**: every LSP request (documentSymbol, hover, inlayHint) blocks for **33 seconds**
before returning empty results. With 6+ open files all blocked, the trace fills with
interleaved "Waiting for nimsuggest to initialize attempt=X" and "Nimsuggest not ready,
retrying..." messages. VS Code eventually restarts the server; the same sequence repeats.
This was observed across sessions spanning 5+ hours in `error_trace33.txt`.

**Fix** (`ls.nim:1504`): delete the sentinel on failure so `getNimsuggestInner` can
retry the spawn on the next request:

```nim
except CatchableError as ex:
  error "Failed to create/restart nimsuggest",
    projectFile = projectFile, error = ex.msg
  # Remove the pending sentinel. Without this, the pending future blocks the
  # hasKey check in getNimsuggestInner permanently — every subsequent request
  # skips the spawn attempt and spins for 33 seconds before giving up.
  if projectFile in ls.projectFiles and
      not ls.projectFiles[projectFile].ns.finished:
    ls.projectFiles.del(projectFile)
```

**Note**: deleting the sentinel means `getNimsuggestInner` will retry the spawn on the
next `tryGetNimsuggest` call (and fail again if the environment is still wrong). This is
preferable to the permanent 33-second block. The underlying root cause — nimsuggest not
on Dock PATH — is addressed by the vscode-nim `setNimDir` fix (see VS Code extension
section).

**Invariant**: `createOrRestartNimsuggest`'s `except CatchableError` block must always
clean up the sentinel (`ls.projectFiles.del(projectFile)`) if the `ns` future was never
completed. Leaving a pending sentinel permanently blocks `getNimsuggestInner`'s spawn
guard.

### 22. Redundant nimsuggest eviction on DID_OPEN when intended project already has a slot (dispatcher.nim)

**Files**: `src/langserver/dispatcher.nim`, `src/langserver/dispatcher_utils.nim`, `src/langserver/transports.nim`

**Diagnosed from**: `rewrite_analysis/quick_traces/2026-08-07e.txt`

**Problem**: When VS Code opens a file matching a `projectMapping` entry (e.g. `tests/tmonorepo3.nim`
→ `src/nimtortoise.nim`), the DID_OPEN path in `processLangserverQueue` calls
`isKnownByANimsuggestSlot` which sends a `known` command to the running `nimtortoise.nim` slot.
This returns `false` — the file hasn't been imported from the project root. The `else` branch then
called `getIntendedProject` (→ `nimtortoise.nim`), saw the pool was full (`maxNimsuggestProcesses=1`),
picked the LRU slot to evict (the perfectly good `nimtortoise.nim` slot), and spawned a **new**
nimsuggest for the **same** project file — wasting another ~20s cold compilation. All queued
NIMSUGGEST requests (documentSymbol, inlayHints, hover) were first drained with `complete(@[])`,
returning empty results, and the fresh nimsuggest still returned `length=0` for the unknown file.

**Root cause**: The code conflated two distinct questions:
- "Is this file in the module graph?" (`isKnown` — may be false for orphan/test files)
- "Do we have the right slot for this file?" (slot-assignment — may be true regardless)

`isKnown=false` does not imply "we need a new nimsuggest". It means the file isn't transitively
imported from the project root. The existing slot is still the correct one to serve it.

**Fix A — primary** (`dispatcher.nim`): After `getIntendedProject` resolves `projectFile`, add a
check before the canSpawn/evict logic:

```nim
if ls.pool.slots.hasKey(projectFile):
  # Slot already running for intended project — assign directly, no spawn needed.
  ls.addFileToOpenFiles(ls.pool.slots[projectFile], q.didOpen.textDocument)
else:
  # ... canSpawn / evict logic (indented inside else)
```

**Fix B — secondary** (`dispatcher_utils.nim`): `addFileToOpenFiles` called `assignUri` (updating
`slot.ownedUris`) but did not update `ns.openFiles` (the `OrderedSet` on the `NimSuggest` TCP
object). `execSpawn` copies `ownedUris` → `ns.openFiles` at spawn time, so files opened on an
already-READY slot were never reflected in `getLspStatus`. After `assignUri`, add:

```nim
if nimsuggestSlot.state == SlotState.READY:
  nimsuggestSlot.ns.read.openFiles.incl(params.uri)
```

Required adding `std/sets` to `dispatcher_utils.nim` imports.

**Fix C — noise** (`transports.nim`): `addRpcToCancellable`'s callback fires when a future
completes after a `$/cancelRequest` has already removed its ID from `pendingRequests`. The
resulting `KeyError` was logged as `ERR`. Downgraded to `debug "Request already cancelled; id not in pending requests"`.

**Cleanup**: Removed the `nimsuggestPath == ""` guard from the `else` branch. After
`waitForLsInitialized()` (called at the top of the queue drain loop), `initNimsuggestInstances`
has already set `pool.nimsuggestPath`. The guard was a pre-`waitForLsInitialized` belt-and-suspenders.

### 23. DID_OPEN orphans processes + DID_CLOSE leaves slots in pool (dispatcher.nim)

**Files**: `src/langserver/dispatcher.nim`

**Diagnosed from**: `rewrite_analysis/quick_traces/2026-08-08c.txt`

**Problem**: Three related bugs in `processLangserverQueue`'s FILE_ACCESS handling caused nimsuggest
processes to accumulate and never be cleaned up.

#### Bug A — Orphaned processes: missing `hasKey` check before spawning intended project

When a file matched a `projectMapping` regex (e.g. `tests/textensions.nim` → `src/nimtortoise.nim`),
`isKnownByANimsuggestSlot` returned `false` (the file isn't transitively imported). The `else` branch
then called `getIntendedProject` (→ `nimtortoise.nim`) and unconditionally created a new slot for that
project without checking whether it was already running:

```nim
# Before — WRONG: overwrites existing pool entry without stopping old process
let newProjectSlot = newSlot(intendedProjectPath, ...)
ls.pool.addSlot(newProjectSlot)   # silently replaces pool["nimtortoise.nim"]
let intendedProjectSpawn = await execSpawn(...)
```

`addSlot` overwrote the existing `nimtortoise.nim` entry in `pool.slots`, dropping the ref to the
old `NimsuggestSlot` without calling `execStop`. The old process (e.g. port 64249) kept running on
the OS but was permanently invisible to the langserver — never tracked, never killed.

The new spawn then found `textensions.nim` wasn't known, stopped itself, removed its pool entry, and
`createNewSuggestSlotAndConsolidate` spawned `textensions.nim` standalone. Net result: one orphaned
OS process per "unknown mapped file" open event.

There was also a dead `elif ls.pool.slots.hasKey(intendedProjectPath)` at the same level — it was
unreachable because the `elif` is only entered when `intendedProjectPath == "" or == filePath`, so
`hasKey` was always false in that branch.

**Fix**: Check `pool.slots.hasKey(intendedProjectPath)` before creating any new slot. If the slot
is already running, assign directly; only spawn if no slot exists yet:

```nim
if ls.pool.slots.hasKey(intendedProjectPath):
  # Slot already running — assign directly, no spawn needed.
  ls.addFileToOpenFiles(ls.pool.slots[intendedProjectPath], q.didOpen.textDocument)
else:
  # No slot yet — spawn it, then check if it knows our file.
  let newProjectSlot = newSlot(intendedProjectPath, ...)
  ls.pool.addSlot(newProjectSlot)
  ... (existing spawn + isKnown check logic)
```

The dead `elif` was removed. The `else` branch (true orphan / file is its own entry point) was
restructured to also check `pool.slots.hasKey(filePath)` before spawning, covering the case where
the file is already running as its own standalone slot.

#### Bug B — Slot never removed on close: wrong pool key in DID_CLOSE

`removeSlot` was called with the URI of the *closed file* converted to a path, not the slot's
project file:

```nim
# Before — WRONG: uses the closed file's path as the pool key
ls.pool.removeSlot(uriToPath(uri))
```

For any file assigned to a project slot (e.g. `dispatcher.nim` → `nimtortoise.nim`), the pool key
is `nimtortoise.nim`, but `uriToPath(uri)` = `dispatcher.nim`. The key didn't exist in the pool,
so `removeSlot` was a silent no-op. The slot accumulated in the pool indefinitely.

**Fix**:

```nim
ls.pool.removeSlot(fileInfo.slot.projectFile)
```

#### Bug C — openFiles never cleared on close

`ls.files.openFiles.del(uri)` was commented out in DID_CLOSE. Closed files remained in `openFiles`
indefinitely, holding stale `NlsFileInfo` refs (with slot pointers, finger tables, etc.).
Additionally, stale entries participated in subsequent `isKnownByANimsuggestSlot` checks — their
slot's `queryMailbox` received KNOWN queries even after the file was nominally closed.

**Fix**: Uncomment the line. `fileInfo` is a captured ref, so the del does not affect subsequent
access to `fileInfo.cancelFileCheck` on the next line.

**Cascade effect of Bug A**: With the orphan bug present, each time a `src/` or `tests/` file was
opened after the pool entry for `nimtortoise.nim` had been removed by a prior open event, the pool
had no entry → `createNewSuggestSlotAndConsolidate` was called for `nimtortoise.nim` again → another
~30s recompile → another orphaned process. This repeated on every new file open until server restart.

**Invariant (new)**: Never call `ls.pool.addSlot(newSlot)` for a `projectFile` without first
checking `pool.slots.hasKey(projectFile)`. Adding a slot for a key that already exists silently
orphans the running process. Always check → assign directly if slot exists, spawn only if absent.

**Invariant (new)**: In DID_CLOSE, always use `fileInfo.slot.projectFile` as the `removeSlot` key,
never the closed file's URI/path. The pool is keyed by entry-point project file, not by the
individual file being closed.

---

## Measured performance (traces 13 and 14)

These traces were collected with all fixes applied, launching VS Code from the terminal
(correct PATH, `~/.nimble/bin/nimble` used).

### Startup timing

| Phase | Trace 13 session 1 | Trace 14 (empty NimCache) |
|-------|-------------------|--------------------------|
| `initialize` handshake | 64ms | 13ms |
| nimble dump | ~4 sec | ~1–2 sec |
| nimsuggest cold-compile | ~11 sec | ~11 sec |
| **Total: initialize → nimsuggest ready** | **~17 sec** | **~14 sec** |

The trace 14 pending hover request self-reports `"11 seconds, 168 milliseconds"` at the
exact moment nimsuggest became ready, independently confirming the cold-compile duration.

### Comparison to pre-fix baseline

| Metric | Before this branch | After all fixes |
|--------|-------------------|-----------------|
| Startup (Dock launch, wrong nimble) | **1+ minute** | N/A (vscode-nim fix pending) |
| nimble dump (correct binary) | tens of seconds (UNSAT) | **~1–4 sec** |
| nimsuggest cold-compile (empty NimCache) | **~53 sec** (pre-fix #10) | **~11 sec** |
| `extension/tasks` | ~13 sec | **~1 sec** |
| Server crashes per session | frequent | **zero** (traces 13 and 14) |

### Session stability

- **Trace 13**: server crashed after ~3 minutes (`removeIdleNimsuggests` bug, now fixed).
  Second session (after auto-restart) ran cleanly.
- **Trace 14**: single session, ran cleanly for its full 42-second duration with
  `"projectErrors": []` at close. No crashes, no SIGSEGV.

---

## SIGSEGV in nimsuggest: diagnosis

This is documented here because the crash was diagnosed in detail and the mechanism
is non-obvious.

**Symptom**: `ERR NimSuggest Error (stderr) err="SIGSEGV: Illegal storage access.
(Attempt to read from nil?)"` in the LSP trace, followed by automatic nimsuggest
restart. Can happen multiple times per session.

**The crash site** (`nimsuggest.nim:1156`, Nim 2.2.10):
```nim
of ideSug, ideCon:
    graph.markDirtyIfNeeded(file.string, fileIndex)
    graph.recompilePartially(fileIndex)   # catches ALL exceptions silently
    let m = graph.getModule fileIndex     # returns nil if both recompiles failed
    incl m.flags, sfDirty                 # ← SIGSEGV if m is nil
```
A nil guard exists elsewhere in the same file (`if m != nil and m.ast != nil:`),
so its absence here is a **deliberate design choice, not an oversight**.

**Why the crash is intentional**: when `getModule` returns nil, both
`recompilePartially` and `recompileFullProject` have already failed silently. The
module graph is in an unknown, potentially corrupted state. There are two options:

1. Guard the nil, return empty results, keep running.
2. Crash and let the supervisor restart cleanly.

Option 1 is arguably worse: nimsuggest would continue serving requests backed by a
corrupted module graph, producing silently wrong suggestions and hover results —
misleading rather than absent. Option 2 forces a clean restart via the langserver's
crash-recovery mechanism (`onErrorCallback` → `createOrRestartNimsuggest`).
Nimsuggest is architecturally a *restartable subprocess* supervised by the
langserver; it is not designed to self-recover from corrupted internal state. This
mirrors Erlang's "let it crash" philosophy: terminate the worker loudly and restart
it clean, rather than limp on in a degraded state that is harder to diagnose.
The SIGSEGV is the signal that triggers the restart.

**How to identify the triggering command**: the `projectErrors` list in
`extension/statusUpdate` shows which commands failed *after* the crash (socket
closed). To find the command that *caused* it, look for the last `DBG Started...`
line with no matching `DBG CPU Time` line — that is the in-flight `sug` command.

**All observed crashes are `sug` commands**, never inlayHints or other commands
despite what `projectErrors` implies.

**Root trigger**: after a `.nim` file rename, `recompilePartially` fails on the
now-missing old file; `recompileFullProject` also fails because the graph is stale.
Both exceptions are caught silently. `getModule` returns nil. Fixed by fix #11.

**Nimsuggest source** is available locally at
`/Users/dp/.nimble/nimbinaries/nim-2.2.10/nimsuggest/nimsuggest.nim`.

---

## Current state of `getNimbleDumpInfo`

The nimble dump call is **re-enabled**. Trace 13 and trace 14 both show
`DBG Starting nimble dump for nimbleFile=.../chordite.nimble` running during the
`initialized` handler (from `initNimsuggestInstances`) and completing in ~1–4 seconds
using `~/.nimble/bin/nimble` (v0.22.2, the correct binary). The dump now produces
`nimDir`, `entryPoints`, and `srcDir` successfully.

Two concurrent nimble dump calls occur at first open (one from `initNimsuggestInstances`,
one from `createOrRestartNimsuggest` via `didOpenFile`). Both complete successfully and
populate the in-memory cache; the duplication is mildly wasteful but harmless.

The dump was previously disabled as an experiment (`let info = ""`). With the correct
nimble binary on PATH (terminal launch), the dump is fast and safe. The Dock-launch
problem (wrong binary → UNSAT) is addressed separately in the vscode-nim extension fix.

---

## The VS Code extension: the actual source of the nimble dump UNSAT

The `vscode-nim` extension (fork at `/Users/dp/Desktop/software_libraries/vscode-nim`)
contains `setNimDir` in `src/nimvscode.nim` which calls `nimble dump` unconditionally
on every extension activation, from the extension host process (`Code Helper (Plugin)`).

### Why `setNimDir` exists

`setNimDir` runs `nimble dump` to extract two fields:
- **`nimDir`**: the nim binary directory, used by `getNimCmd()` and `getNimExecPath()`
  for build/run/format commands.
- **`testEntryPoint`**: the test entry point file, used as fallback by the test runner
  if `nim.test.entryPoint` is not set in VS Code settings.

### Why it triggers UNSAT

`nimble dump` calls `getNimDir` internally before producing any output, to decide which
nim compiler to use for the dump. This runs the SAT solver on `requires nim >= 2.2.0`.
When launched from the Dock, VS Code's PATH is limited — the extension finds
`/usr/local/bin/nimble` (Homebrew v0.18.2) rather than `~/.nimble/bin/nimble` (v0.22.2).
The older nimble cannot find nim 2.2.x in its package database → UNSAT → exponential.

### Architectural issue

`setNimDir` is called unconditionally at activation regardless of `provider` setting.
In **LSP mode** (the user's config), the langserver already handles all nim/nimsuggest
invocations. The `nimDir` value from `setNimDir` is not needed — `getNimCmd()` and
`getNimExecPath()` both have safe PATH fallbacks when `nimDir` is empty.

### The fix (tracked in `vscode-nim` fork, branch `fix/setNimDir-bypass-sat-solver`)

Pass `--nim:<path>` to `nimble dump`, where `<path>` is found via `getBinPath("nim")`.
`getBinPath` already prepends `~/.nimble/bin` to the PATH search and follows symlinks,
so it correctly finds nim even from a Dock-launched VS Code. Passing `--nim:` explicitly
tells nimble which nim to use, bypassing the `getNimDir`/SAT solver step entirely:

```nim
proc setNimDir(state: ExtensionState) =
  if not vscode.workspace.workspaceFolders.toJs().to(bool):
    return
  let workspacePath = vscode.workspace.workspaceFolders[0].uri.fsPath
  let nimPath = getBinPath("nim")
  let args =
    if nimPath != "" and not nimPath.isNil:
      @["dump".cstring, ("--nim:" & $nimPath).cstring]
    else:
      @["dump".cstring]
  var process = cp.spawn(
    getNimbleExecPath(), args, SpawnOptions(shell: true, cwd: workspacePath)
  )
  # stdout handler unchanged
```

See `TODO.md` in the langserver repo for the full implementation plan.

### Other nimble calls in the extension

| File | Call | When | Status |
|------|------|------|--------|
| `nimvscode.nim:419` | `nimble setup` | `.nimble` found, `nimble.paths` absent | Guarded by `nim.nimbleAutoSetup` setting; not a startup problem |
| `nimImports.nim:113` | `nimble list -i` | Import completion init | Independent of `nimDir`; not a startup problem |
| `nimImports.nim:134` | `nimble --y dump <pkg>` | Per-module, import completion | Synchronous but not on the critical startup path |
| `nimLsp.nim:143` | `nimble install nimlangserver` | LSP not found | One-time, user-triggered |

---

## Remaining problem

### Cold-compilation gap in nimsuggest

**Status**: Reduced to ~11 seconds (from the previously measured ~53 seconds) by fix #10
(`nimble.paths` forwarding). The remaining gap is pure Nim compiler parse + type-check
time for the project's import tree, with no nimble involvement.

**Mechanism**: On first query after nimsuggest starts, the Nim compiler does a full
semantic analysis pass of the project and all its imports. For the `user_interfaces`
sub-module this takes ~11 seconds. Subsequent queries are fast (< 1s) because nimsuggest
caches results in NimCache on disk. NimCache persists between VS Code sessions, so the
second session in trace 13 also initialised in ~12 seconds (NimCache was still cold after
the process crash cleared in-memory state, but disk cache was present from session 1).

**Next steps** (see `POSSIBILITIES.md`):
1. **Pre-spawn nimsuggest during `initialized`** — let it warm up in the background
   while VS Code finishes loading. By the time the user opens a file, compilation may
   already be done.
2. **Filesystem-scan `--path:` injection** — scan `.nimble` files in the workspace root
   to add `--path:` flags for all local sub-modules without calling nimble. This may
   reduce the remaining ~11s further for larger entry points.

---

## Architecture notes

### Key files

> These refer to the **old** pre-rewrite architecture (`ls.nim`, `routes/lsp.nim`). For the
> `dp-rewrite` branch see "New directory structure" below.

- `ls.nim` — `LanguageServer` type, `getNimbleDumpInfo`, `initNimsuggestInstances`,
  `createOrRestartNimsuggest`, `findNimblePaths`, `waitForWorkspaceConfiguration`,
  `shouldSpawnNimsuggest`, `leastRecentlyUsedProjectFile`, `getProjectFile`,
  `getIntendedProjectFile`, `warnIfUnknown`, `didDeleteFile`
- `suggestapi.nim` — `createNimsuggest` (gains `nimPaths` param), `detectNimsuggestVersion`,
  `getNimsuggestCapabilities`, the async nimsuggest process lifecycle
- `routes/lsp.nim` — LSP message handlers, `startNimbleProcess`, `tasks`, `execute`,
  `restart` template (clears `errorCallback` + `crashedFiles` before stop)
- `utils.nim` — utility procs

### Startup sequence (current)
1. VS Code → `initialize`
   - Stores `lspInitializeParams`, returns server capabilities
   - Does NOT spawn nimsuggest
2. VS Code → `initialized`
   - Requests config from client (`workspace/configuration`)
   - `waitForWorkspaceConfiguration()` — polls until config arrives
   - `initNimsuggestInstances(rootPath)` — with real config; runs nimble dump to get
     `entryPoints` (see "Current state of getNimbleDumpInfo" section)
3. VS Code → `textDocument/didOpen <file>`
   - `waitForWorkspaceConfiguration()` — immediate (already done)
   - `getProjectFile` with real config (projectMapping regex applied; reuse if limit hit)
   - `getIntendedProjectFile` — mapping-only lookup, no reuse fallback
   - `findNimblePaths(projectFile)` — finds nimble.paths, extracts flags
   - `createOrRestartNimsuggest` → `createNimsuggest` with `--noNimblePath --path:...`
   - Nimsuggest starts; cold-compilation begins (~11s with warm PATH + nimble.paths)
   - `warnIfUnknown(ns, uri, projectFile, intendedProjectFile)` — fire-and-forget;
     three branches on `isKnown=false`:
     1. `intendedProjectFile != projectFile` → restart for intended project ("latest file wins", fix #13)
     2. `not canHandleUnknown` → show warning (file not in any known project)
     3. `canHandleUnknown=true` and `intendedProjectFile == projectFile` → standalone path (fix #18/#19):
        - Guard: if nimsuggest already running for `path` as its own project, skip.
        - `canSpawn = await ls.shouldSpawnNimsuggest()`
        - **Spawn alongside** (`canSpawn=true`): reassign only `uri`'s projectFile future
          to `path` BEFORE calling `createOrRestartNimsuggest(path, uri)`. No redirect alias,
          no reassignment of other open files. Old nimsuggest keeps running.
        - **Kill and replace** (`canSpawn=false`): cascade prevention check (redirect-alias
          detection), then stop old nimsuggest, spawn new one, create redirect alias, reassign
          all open files pointing to old project.

### `getWorkspaceConfiguration` behaviour
- `getWorkspaceConfiguration()` — returns current state immediately, empty if not yet received
- `getAndWaitForWorkspaceConfiguration()` — directly awaits the shared future (deadlock risk in sync)
- `waitForWorkspaceConfiguration()` — polls with 50ms intervals, 30s timeout, safe in async,
  does NOT cancel the shared future. **Never pass `ls.workspaceConfiguration` to
  `utils.withTimeout`** — that proc cancels the future on timeout.

### `nimble.paths` and `config.nims`
- `nimble setup` generates `nimble.paths` in the project root with `--noNimblePath`
  and one `--path:` per dependency.
- `config.nims` auto-includes `nimble.paths` if it exists (standard nimble workflow).
- `nimble.paths` is **gitignored** — every user must run `nimble setup` after cloning.
- Our `findNimblePaths` reads this file and passes its contents directly to nimsuggest,
  so the Nim compiler inside nimsuggest gets the same paths whether or not it finds
  `config.nims` itself.

### `extension/tasks` timing
Previously took ~13 seconds (NimScript compile). Now typically 0.8–1.5 seconds. This
is because `nimble.paths` and `config.nims` are present, so the NimScript compiler
doesn't need to resolve package paths via the SAT solver.

### Known cosmetic issues after "latest file wins" restart

**Duplicate `nimsuggestInstances` in `extension/statusUpdate`** (fixed in fix #19):
redirect aliases (where two keys point to the same `Project`) previously caused the
status reporter to emit two identical entries. Now `getLspStatus` deduplicates by port
via `seenPorts: HashSet[int]`, so only one entry appears per running nimsuggest process.
The "spawn alongside" path (fix #19) does not create redirect aliases at all.

**`isKnown` timeout for the project root file**: `warnIfUnknown` is called for the
project root file (e.g. `user_interfaces.nim`) immediately after nimsuggest initialises.
Nimsuggest is still running its first compilation pass at this point, so the `known`
command times out. Since `intendedProjectFile == projectFile` for the root file, no
restart is triggered regardless — the timeout is benign.

**First `warnIfUnknown` for the project entry-file skips during "kill and replace" compile**:
when `fraction_layouts.nim` triggers a "kill and replace" standalone restart, `warnIfUnknown`
for `user_interfaces.nim` fires concurrently inside the event loop while `waitFor createNimsuggest`
is blocking (~8–11s). At that point, `ls.projectFiles["user_interfaces.nim"]` still holds the
original (stopped) project entry — the redirect hasn't been applied yet. The "already running"
guard fires, skipping the restart. This is correct: starting a second nimsuggest during the
blocking compile would violate `maxNimsuggestProcesses`. `user_interfaces.nim` features are
restored on next focus. With `maxNimsuggestProcesses=2` this situation does not arise — the
"spawn alongside" path is taken and neither nimsuggest is stopped.

### Chronos async notes
- `putEnv` before `await startProcess(...)` is captured synchronously before first `await`.
- `waitFor` inside `{.gcsafe, raises: []}` procs is safe but blocks the coroutine.
- Do not call `waitFor getAndWaitForWorkspaceConfiguration()` from sync context — deadlock.

---

## Project-specific context

- **User's project**: `/Users/dp/Desktop/funis/funis` — "chordite" monorepo, 30+ sub-modules
- **Root `.nimble`**: `chordite.nimble`, requires only `nim >= 2.2.0`
- **`nimble.paths`** for funis: `--noNimblePath` + `--path:"/Users/dp/Desktop/funis/funis"` (one entry)
- **Nim version**: 2.2.10 at `~/.nimble/pkgs2/nim-2.2.10-.../bin/`
- **VS Code config**: `maxNimsuggestProcesses: 2`, extensive `projectMapping` regexes
- **Langserver**: built with Nim 2.0.8, depends on chronicles/chronos/stew/json_rpc
- **Langserver `nimble.paths`**: 21 `--path:` entries pointing into pkgs2 + project root

### Funis monorepo path structure

The funis project is a monorepo of independent nimble subpackages. Each subpackage
has its own `config.nims` that adds `switch("path", ...)` entries for its dependencies
within the monorepo. For example, `controller/user_interfaces/config.nims` adds:
```
switch("path", thisDir() & "/../ravel/src")
switch("path", thisDir() & "/../user_interfaces_shared/src")
switch("path", thisDir() & "/../../model/funis/src")
# ... etc.
```

When nimsuggest is started for `user_interfaces/src/user_interfaces.nim`, the Nim
compiler walks up from the project file's directory and loads both:
1. `controller/user_interfaces/config.nims` — subpackage-specific paths
2. Root `config.nims` — includes `nimble.paths` (`--noNimblePath --path:...`)

This means nimsuggest gets all necessary paths even though `nimble.paths` only has
one `--path:` entry. The `workingDir` we set does not affect which `config.nims`
files are loaded — Nim keys that lookup to the project file's directory tree, not
the working directory.

## Template instantiation errors and nimsuggest diagnostics

### Why nimsuggest misses template errors that the compiler catches

The Nim compiler and nimsuggest can disagree on whether code is erroneous. The canonical
example: `nim c liszt.nim` reported `Error: undeclared identifier: 'unselectedColor'`
at `proportion_temperament_ui_doms.nim:323`, but navigating to that file in VS Code
showed no error squiggles.

**Root cause — templates are lazy**: Template errors only surface at *instantiation*
sites, not at the template's definition site. The compiler sees the error because
`liszt.nim` transitively instantiates the template with arguments that cause
`unselectedColor` to be required in scope. Nimsuggest, anchored to a different project
root (`user_interfaces.nim`), never traverses that instantiation path and therefore
never sees the error.

**Root cause — project file mismatch**: Nimsuggest runs per project root. A file can
be *open* in the editor under one project root while the error only manifests when
compiled from a *different* project root. The langserver has no way to know this without
compiling all projects that import the file.

**What nimsuggest's `highlight` command does**: The `highlight` (hover) command does a
quick symbol lookup via `recompilePartially`. Returning `length=0` in 136ms means it
found nothing at that position — it is not a full semantic analysis. It does not
instantiate all templates in scope.

### Could the langserver be changed to catch these errors?

**Within the same project**: Nimsuggest has a `chk` command specifically for reporting
errors. Unlike `highlight`, `chk` runs `recompilePartially` and collects the resulting
error list. Calling `chk` on `textDocument/didSave` and pushing results via
`textDocument/publishDiagnostics` would catch template instantiation errors that occur
within the current project's compilation path. Alternatively, `nim check <projectFile>`
(full semantic analysis, no codegen) could be run as a background linter on save.

**Cross-project template errors**: Not catchable without compiling every project that
imports the modified file. The langserver would need a reverse dependency map across
all projects and to run `nim check` on each — impractical.

### Why `nim check` on save is not worth adding for this project

The vscode-nim extension recommends enabling VS Code Auto Save. Auto Save has several
modes — **it does NOT save on every keystroke**:
- **afterDelay** (default, typically 1000ms) — saves N ms after the last edit
- **onFocusChange** — saves when the editor loses focus
- **onWindowChange** — saves when the window loses focus

Even with `afterDelay` at 1 second, active typing triggers saves constantly. For the
funis monorepo, `nim check controller/liszt/src/liszt.nim` takes 10–50+ seconds (same
cold-compile cost as nimsuggest first load). Running it on every save would stack
overlapping compiler processes, each consuming a full compiler's worth of CPU and
memory. Cancelling the previous process before starting a new one helps but does not
eliminate the problem.

**Verdict**: `nim check` as a background linter has poor cost-benefit for this project
size. The nimsuggest `chk` command (incremental, fast) is the more appropriate tool for
in-editor diagnostics, and cross-project template errors remain outside what a
single-entry-point language server can reasonably detect.

---

## Nimsuggest v3 vs v4 protocol reference

The langserver always starts nimsuggest with `--v4` (`suggestVersion = 4`). Understanding
the protocol split is essential when diagnosing command-level failures.

### Command dispatch

All commands go through `execCmd` (same for all versions). Two special commands are
handled here before version-specific routing:
- `known` → `ideKnown`: returns `fileInfoKnown(conf, file)` — works in all versions
- `project` → `ideProject`: returns `conf.projectFull` — works in all versions

Remaining commands are routed to:
- `suggestVersion < 3`: `executeNoHooks` (old protocol)
- `suggestVersion >= 3`: `executeNoHooksV3` (v3/v4 protocol, same proc)

### Unknown file handling — the critical v3/v4 difference

**v3 (`executeNoHooks`)**:
```nim
var isKnownFile = true
let dirtyIdx = fileInfoIdx(conf, file, isKnownFile)  # sets isKnownFile=false if new
if not isKnownFile:
  graph.clearInstCache(dirtyIdx)
  graph.compileProject(dirtyIdx)  # ← unconditional compile for unknown files
```
Unknown files are compiled standalone on ANY command, before any command-specific logic.

**v4 (`executeNoHooksV3`)**:
```nim
fileIndex = fileInfoIdx(conf, file)  # no isKnownFile output
# Only recompiles if:
elif cmd in {ideHighlight, ideDef, ...} and
     (graph.needsCompilation(fileIndex) or cmd in {ideSug, ideCon}):
  graph.recompilePartially(fileIndex)
```
`needsCompilation(fileIndex)` checks `getModule(fileIndex) != nil and isDirty(module)`.
For a file with no module in the graph, `getModule` returns nil → `needsCompilation`
returns **false** → `recompilePartially` is never called → all commands return `length=0`.

**Consequence**: the `unknownFile` capability advertised by nimsuggest is effectively
non-functional in v4 for files that were never imported into the project. The langserver
works around this by restarting nimsuggest with the file as its own entry point (fix #18).

### Command coverage in v4

All commands the langserver sends are correctly handled in v4:

| Command string | v4 handling |
|---|---|
| `sug`, `con`, `def`, `declaration`, `use`, `expand`, `highlight`, `type` | Handled in `executeNoHooksV3` case |
| `chk`, `chkFile`, `changed`, `outline`, `globalSymbols`, `recompile` | Handled in `executeNoHooksV3` case |
| `inlayHints` | Handled in `executeNoHooksV3`; rejected with `err()` for `suggestVersion < 4` |
| `known` | Handled pre-dispatch in `execCmd` (before `executeNoHooksV3`) |
| `mod` | Parser maps `"mod"` → `ideMod`; **discarded** in v4 (`else: myLog "Discarding cmd"`). Was dead code in the langserver (wrong command string "ideMod" sent; zero callers). Removed. |

Note: the `execCmd` parser normalises command strings (`opc.normalize`), so `"chkFile"`
matches `of "chkfile"`, `"globalSymbols"` matches `of "globalsymbols"`, etc.

### Dirty file registration in v4

In v4, every command (except `ideRecompile` and `ideGlobalSymbols`) calls
`msgs.setDirtyFile(conf, fileIndex, dirtyfile)` before any other logic. This means
hover/def/etc. always receive the current stash content even without a prior `changed`
call. Recompilation using that dirty content only happens when `needsCompilation` is
true — which requires `ideChanged` to have previously marked the file dirty via
`graph.markDirtyIfNeeded`. The `checkFile` flow correctly sends `changed` before `chkFile`
to ensure fresh diagnostics.

---

## Complete LSP handler map

> **Note**: This table describes the **old** pre-rewrite architecture (`ls.nim` / `routes/lsp.nim`).
> In the `dp-rewrite` branch, handlers are in `src/handlers/` (split across `request_text_document.nim`,
> `request_extension.nim`, `request_process.nim`, `request_workspace.nim`,
> `notification_files.nim`, `notification_process.nim`). Routes are registered in
> `src/nimtortoise.nim` via `registerLspRoutes`. Line numbers and file paths below are stale.
> For the rewrite feature parity status (which handlers are complete vs stubbed) see
> `rewrite_analysis/2026-08-07_STATE_OF_THE_REPO.md` → "Feature Parity Checklist".

Every message VS Code can send and where it's handled. All handlers are registered in
`nimlangserver.nim:22-108` via `registerLspRoutes`.

### Request handlers (response required)

| LSP Method | Handler | NS Command(s) sent | Cancellable |
|---|---|---|---|
| `initialize` | `routes/lsp.nim:30` | none | no |
| `textDocument/completion` | `routes/lsp.nim:147` | `sug` | yes |
| `textDocument/definition` | `routes/lsp.nim:175` | `def` | yes |
| `textDocument/declaration` | `routes/lsp.nim:191` | `declaration` | yes |
| `textDocument/typeDefinition` | `routes/lsp.nim:312` | `type` | yes |
| `textDocument/documentSymbol` | `routes/lsp.nim:337` | `outline` | yes |
| `textDocument/hover` | `routes/lsp.nim:398` | `highlight`, `expand`? | yes |
| `textDocument/references` | `routes/lsp.nim:454` | `use` | no |
| `textDocument/prepareRename` | `routes/lsp.nim:470` | `def` | yes |
| `textDocument/rename` | `routes/lsp.nim:492` | `use` | yes |
| `textDocument/inlayHint` | `routes/lsp.nim:566` | `inlayHints` | yes |
| `textDocument/signatureHelp` | `routes/lsp.nim:687` | `con` | yes |
| `textDocument/formatting` | `routes/lsp.nim:768` | none (nimpretty) | yes |
| `textDocument/documentHighlight` | `routes/lsp.nim:790` | `highlight` | yes |
| `textDocument/codeAction` | `routes/lsp.nim:605` | none (static list) | no |
| `workspace/executeCommand` | `routes/lsp.nim:640` | `recompile`, `chk` | no |
| `workspace/symbol` | `routes/lsp.nim:778` | `globalSymbols` | yes |
| `shutdown` | `routes/lsp.nim:812` | none | no |
| `exit` | `routes/lsp.nim:820` | none | no |
| `extension/macroExpand` | `routes/lsp.nim:234` | `expand` | no |
| `extension/status` | `routes/lsp.nim:260` | none | no |
| `extension/capabilities` | `routes/lsp.nim:266` | none | no |
| `extension/suggest` | `routes/lsp.nim:271` | restart/check | no |
| `extension/tasks` | `routes/lsp.nim:851` | none (nimble) | no |
| `extension/runTask` | `routes/lsp.nim:870` | none (nimble) | no |
| `extension/listTests` | `routes/lsp.nim:888` | none (nim compile) | no |
| `extension/runTests` | `routes/lsp.nim:904` | none (nim run) | no |
| `extension/cancelTest` | `routes/lsp.nim:922` | none | no |

### Notification handlers (no response)

| LSP Method | Handler | NS Command(s) sent | State mutated |
|---|---|---|---|
| `initialized` | `routes/lsp.nim:935` | none | `projectFiles`, `entryPoints` |
| `textDocument/didOpen` | `routes/lsp.nim:1055` → `ls.didOpenFile` | `known` | `openFiles`, `projectFiles`, `ns.openFiles` |
| `textDocument/didChange` | `routes/lsp.nim:958` | none (deferred) | `openFiles.changed`, stash file |
| `textDocument/willSaveWaitUntil` | `routes/lsp.nim:979` | none | — |
| `textDocument/didSave` | `routes/lsp.nim:1001` → `ls.didSaveFile` | `changed`, `chk` | `openFiles.changed`, `crashedFiles` |
| `textDocument/didClose` | `routes/lsp.nim:1050` → `ls.didCloseFile` | none | `openFiles`, `ns.openFiles` |
| `workspace/didRenameFiles` | `routes/lsp.nim:1060` → `ls.didRenameFile` | `recompile` | `openFiles`, `projectFiles`, `ns.openFiles` |
| `workspace/didDeleteFiles` | `routes/lsp.nim:1066` → `ls.didDeleteFile` | `recompile` | `openFiles`, `ns.openFiles` |
| `workspace/didChangeConfiguration` | `routes/lsp.nim:1072` | none/restart all | `workspaceConfiguration`, `projectFiles` |
| `$/cancelRequest` | `routes/lsp.nim:943` | none | `pendingRequests` |
| `$/setTrace` | `routes/lsp.nim:955` | none | — |

---

## Key data structures

### `NlsFileInfo` (`ls.nim:100-107`)

One entry in `ls.openFiles` per open URI. Both tables must stay in sync:

```nim
projectFile*: Future[string]      # Resolves to projectFile path once assigned
changed*: bool                     # True if unsaved edits exist (stash is authoritative)
fingerTable*: seq[seq[...]]       # UTF-8 → UTF-16 position mapping (reset on every change)
cancelFileCheck*: Future[void]    # Cancel token for deferred checkFile
checkInProgress*: bool            # Guard: checkFile is already running
needsChecking*: bool              # Queued re-check while checkInProgress was true
textDocument*: TextDocumentItem   # Original document metadata from didOpen
```

### `Project` (`suggestapi.nim:110-118`)

One entry in `ls.projectFiles` per managed entry point:

```nim
ns*: Future[Nimsuggest]           # Resolves when nimsuggest TCP port is ready
file*: string                      # Project file path (entry point)
process*: AsyncProcessRef          # Subprocess handle
errorCallback*: Option[...]        # onErrorCallback — CLEAR before intentional stop
errorMessage*: string              # Last error from stderr
failed*: bool                      # Set by markFailed(); gates errorCallback
lastCmd*: string                   # Last sent command string (used to extract crashedFile)
lastCmdDate*: Option[DateTime]    # Last activity (used by removeIdleNimsuggests)
```

### `Nimsuggest` (`suggestapi.nim:88-105`)

```nim
port*: int                                 # TCP port to connect to
openFiles*: OrderedSet[string]             # URIs this instance knows about
                                           # ⚠ Never iterate this with await in the loop body
capabilities*: set[NimSuggestCapability]   # {nsCon, nsUnknownFile, nsExceptionInlayHints}
protocolVersion*: int                      # 3 or 4 (always 4 with current args)
timeout*: int                              # ms before restartCallback fires
requestQueue*: Deque[SuggestCall]          # Pending TCP calls
```

---

## The two-table state model

The single most common source of bugs. Always think of them together:

```
ls.openFiles   Table[uri → NlsFileInfo]      ← LSP ground truth, all open URIs
ns.openFiles   OrderedSet[uri]               ← Per-nimsuggest tracking, subset of ls.openFiles
```

**They are deliberately separate** — there can be multiple nimsuggest instances each owning a
disjoint subset of open files. The nimsuggest protocol has no "close" command, so `ns.openFiles`
only tracks which URIs that instance was told to care about.

**They must be kept in sync manually.** Every `ls.openFiles` insertion/deletion must be mirrored
to the correct `ns.openFiles`:

| Operation | `ls.openFiles` | `ns.openFiles` |
|---|---|---|
| `didOpenFile` | `ls.openFiles[uri] = new NlsFileInfo` | `ns.openFiles.incl(uri)` |
| `didCloseFile` | `ls.openFiles.del(uri)` | `project.ns.read().openFiles.excl(uri)` for each project |
| `didRenameFile` | del old, insert new | excl old, incl new |
| `didDeleteFile` | `ls.openFiles.del(uri)` | `ns.openFiles.excl(uri)` |
| `makeIdleFile` | del from `openFiles`, insert into `idleOpenFiles` | `ns.openFiles.excl(uri)` |

**The deadly pattern**: a `for uri in ns.openFiles` loop that contains any `await` point.
At each `await`, the Chronos event loop yields and `didCloseFile` can call `excl`, mutating
the `OrderedSet` while the iterator is live. Nim detects this and raises a fatal exception.
**Always snapshot first**: `for uri in ns.openFiles.toSeq:` (fix #14, `ls.nim:1626`).

---

## The stash (dirtyfile) mechanism

How unsaved edits reach nimsuggest without corrupting the disk file:

1. `textDocument/didChange` → write content to `storageDir/(hash(uri).toHex & ".nim")`,
   set `ls.openFiles[uri].changed = true`.
2. Any nimsuggest request checks `ls.openFiles[uri].changed`. If true, the stash path is
   passed as the `dirtyfile` argument: `sug "/disk/file.nim";"/stash/abc.nim":42:15`.
3. `textDocument/didSave` → `ns.changed(file, "")` (empty dirtyfile = use disk),
   then `ls.openFiles[uri].changed = false`.

In v4, nimsuggest calls `msgs.setDirtyFile(fileIndex, dirtyfile)` before any command logic,
so position commands always use the stash content when one is provided — no prior `changed`
call needed for hover/definition/etc.

---

## Request pipeline: handler → TCP → response

```
Route handler
  → tryGetNimsuggest(uri)
      → await ls.openFiles[uri].projectFile   (resolves to projectFile string)
      → await ls.projectFiles[pf].ns          (resolves to Nimsuggest)
      → if ns.failed: return none
  → ns.<command>(file, stashPath, line, col)
      → enqueue SuggestCall in ns.requestQueue
      → processQueue() picks it up, opens TCP to ns.port
      → sends command string, reads lines until ".\n"
      → if empty content: markFailed("Server crashed")
                          (complete(@[]) not fail — fix #17)
      → else: parse tab-separated Suggest objects
  → map Suggest → LSP types (Location, CompletionItem, Hover, etc.)
  → respond to VS Code
```

**Timeout** runs in parallel: if `req.future` is not resolved within `ns.timeout` ms,
`restartCallback` fires and calls `createOrRestartNimsuggest`. The timed-out request gets
empty results.

---

## `createOrRestartNimsuggest` — slot reservation

The function must reserve `ls.projectFiles[pf]` with a pending `Project` **before the first
`await`**. Otherwise two concurrent `didOpenFile` calls for the same project both pass the
"not in projectFiles" check and spawn two processes:

```nim
# This assignment happens synchronously, before any await:
ls.projectFiles[projectFile] = Project(ns: newFuture[Nimsuggest]("pending"))
# ... then async work proceeds
```

If you ever add code that creates a nimsuggest and the initial slot reservation is pushed past
an `await`, you will get duplicate processes.

---

## Consolidated invariants

These are constraints that must hold in all future code, learned from hard-to-debug crashes:

1. **Clear `errorCallback` before `project.stop()`** — any intentional stop must set
   `project.errorCallback = none(ProjectCallback)` first. Otherwise in-flight TCP commands
   trigger `onErrorCallback` on the killed process, adding spurious entries to `crashedFiles`
   and launching a competing auto-restart. Established by fix #13/14; currently upheld in
   the `restart` template and `warnIfUnknown`. Any new code that stops a project must do the same.

2. **Snapshot `ns.openFiles` before async iteration** — `for uri in ns.openFiles.toSeq:` not
   `for uri in ns.openFiles:`. Any `await` inside the loop body allows `didCloseFile` to call
   `excl` on the live set, which Nim detects as a fatal mutation during iteration (fix #14).

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
    new `ns.openFiles`. Reassign first, then spawn.

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

15. **Stash path must be collision-resistant** — `hash(uri).toHex & ".nim"` as a stash
    filename is vulnerable to hash collisions. Two URIs mapping to the same hash silently
    overwrite each other's edit buffer; nimsuggest then hovers on the wrong code with no
    error. Use a monotonic counter or the full URI with separators replaced as the key.

16. **Guard `fileInfo.slot` before use in `didClose`/`didSave` paths** — `slot` in
    `NlsFileInfo` may be nil if `didClose` fires for a URI whose `didOpen` has not yet
    completed slot assignment (nimsuggest still cold-compiling). Always check
    `if fileInfo.slot != nil:` before `fileInfo.slot.unassignUri(uri)` or accessing
    `fileInfo.slot.queryMailbox`.

---

## Potential remaining races (unconfirmed, watch for)

1. **Redirect alias double-stop**: after `ls.projectFiles[old] = ls.projectFiles[new]`,
   both keys point to the same `Project`. Status display is now deduplicated by port (fix #19).
   But any code iterating `ls.projectFiles.values` and calling `stop()` on each will stop
   the shared process twice — the second call is a no-op if the process is already dead, but
   could cause issues if it is not. Only the "kill and replace" path creates redirect aliases;
   the "spawn alongside" path does not.

2. **Concurrent `didOpen` for the same URI**: if VS Code sends two `didOpen` for the same URI
   in rapid succession (e.g. after reload + rename), both may pass the `uri in ls.openFiles`
   guard before the first one writes the entry. The second insertion would overwrite the first,
   losing the completed `projectFile` future.

3. **`warnIfUnknown` timeout is noisy but benign for the project root file**: the `known`
   command times out during the first compilation pass. Because `intendedProjectFile == projectFile`
   for root files, no restart is triggered. The warning log is expected and can be ignored.

4. **`warnIfUnknown` during `waitFor createNimsuggest` blocking period**: `createOrRestartNimsuggest`
   is synchronous (`waitFor`) and blocks for the full cold-compile time (~8–11s). Chronos
   spins the event loop inside `waitFor`, so other coroutines (including concurrent
   `warnIfUnknown` calls) can run during this window. The redirect applied AFTER the blocking
   call is not yet visible to these concurrent coroutines. Consequence: the first
   `warnIfUnknown` for files opened concurrently with a standalone restart sees the pre-redirect
   state and may skip (correctly, to avoid two concurrent compiles) or may cascade (now
   prevented by the cascade prevention check). This is a fundamental limitation of the
   synchronous `createOrRestartNimsuggest` design — full resolution would require making it
   truly async with `await`.

---

## Test suite: `tests/`

`tests/` is the single, unified test suite for the `dp-rewrite` branch. It consolidates
what were previously three separate directories (`tests/`, `test_fixes/`, and
`tests_rewrite/`) into one. All tests import directly from `../src/`.

### How to run

```sh
# From repo root — run all tests:
nim c --path:. -r tests/all.nim

# Run a single file (recommended for debugging, clearer output):
nim c --path:. -r tests/<file>.nim
```

Config is in `tests/config.nims`. Fixtures live in `tests/projects/`.

### Test files

| File | Tests | Status | Notes |
|---|---|---|---|
| `tsuggestapi.nim` | 8 | ✓ all pass | TCP protocol + suggestapi |
| `tnimlangserver.nim` | 14 | ✓ all pass | Core LSP integration |
| `tprojectsetup.nim` | 3 | ✓ all pass | Project file detection |
| `textensions.nim` | 7 | ✓ all pass | Extension handlers |
| `tmisc.nim` | 3+ | partial | Idle timeout SIGSEGV (see below); other suites pass |
| `ttestrunner.nim` | 3 | ✓ all pass | Test runner |
| `tfindnimblepaths.nim` | 7 | ✓ all pass | `findNimblePaths` unit tests |
| `tmonorepo.nim` | 13 | 11 pass / 2 FAIL | Fix regressions; see below |
| `tmaxlimits.nim` | 4 | ✓ all pass | Spawn limit, cascade prevention, LRU |
| `tstability.nim` | — | see notes | Stability/crash recovery scenarios |
| `troutingpolicy.nim` | 16 | excluded | Commented out in `all.nim` — investigate separately |
| `tknownbug3.nim` | 1 | excluded | Known unfixed Bug 3; expected to fail |
| `tmcp.nim` | — | excluded | MCP protocol untested |

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

### Known failures

#### `tmisc.nim` — idle nimsuggest SIGSEGV

The "after a period of inactivity, nimsuggest should be stopped" test may crash with
`SIGSEGV: rawAlloc → nimNewObj`. Four root causes were identified and fixes applied:

1. **`tickLs` tail-recursion** (`nimtortoise.nim`): replaced with `while true` + `sleepAsync`.
2. **`tick()` `withValue`+`del`** (`langserver.nim`): replaced with plain table lookup
   before `makeIdleFile` to avoid invalidating a raw pointer into the hash table.
3. **`tick()` ordering** (`langserver.nim`): STOP + `pool.removeSlot` now runs before
   file eviction, not after.
4. **`waitForNotification` tail-recursion** (`lspsocketclient.nim`): replaced with `while` loop.

If the test still fails, focus on `src/langserver/langserver.nim` `tick()` and
`pool.removeSlot()` — the slot object must stay alive until `processNimsuggestQueries`
coroutines exit, otherwise sub-object GC can corrupt the heap.

#### `tmonorepo.nim` — 2 failures

1. **Fix #13 — cross-project restart**: `EVICT_AND_SPAWN` decision is made correctly
   but "Nimsuggest initialized for pkgb" never arrives within the timeout. New test.
2. **Fix #12C — SIGSEGV recovery hover**: hover still returns `JNull` after crash
   recovery triggered by a broken stash + `didSave`. New test.

#### Bug 3 — "assume-known-when-busy" (no fix yet)

When `didOpen` arrives while nimsuggest is busy with `checkFile`, `isKnown` times out
and returns `true` (assumed known). No kill-and-replace or standalone spawn fires.
No retry mechanism — the file is permanently unserved. Hover returns `JNull`.
Documented in `tknownbug3.nim`, excluded from `all.nim`.

### Coverage gaps

| Gap | Status |
|---|---|
| `workspace/didRenameFiles` (fix #7/#11) | `tmonorepo.nim` — passing |
| In-flight command completion on kill (fix #17) | `tmonorepo.nim` — passing |
| Cross-project unknown file restart (fix #13) | `tmonorepo.nim` — **FAILING** |
| SIGSEGV recovery on didSave (fix #12C) | `tmonorepo.nim` — **FAILING** |
| `routingPolicy` unit tests | `troutingpolicy.nim` — excluded from `all.nim` (investigate) |
| Bug 3 "assume-known-when-busy" | `tknownbug3.nim` — excluded (known bug, no retry mechanism) |
| MCP protocol | `tmcp.nim` — excluded |

---

## Debugging approach

Add `debug "..."` calls with the `chronicles` library. The VS Code LSP trace log
(`"nim.logNimsuggest": true`) captures both protocol messages (timestamped) and
langserver debug output in one file. New debug logs added at all nimble call sites
print `HOME`, `PATH`, and `NIMBLE_DIR` to identify which binary is being used.

---

## Rewrite: `dp-rewrite` branch

A ground-up rewrite in `src/`. The old flat-file layout is replaced by a proper module
hierarchy. The dual-queue dispatch design (`langserverQueue` → per-slot `queryMailbox`)
is architecturally sound and cleaner than the original. The code compiles. See
`rewrite_analysis/2026-08-07_STATE_OF_THE_REPO.md` for the senior engineering assessment
and `rewrite_analysis/SOFTWARE_REVIEW.md` for the earlier code-review findings. Other
design documents are in `rewrite_analysis/`.

### New directory structure

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
│   │                           #   handles NIMSUGGEST and FILE_ACCESS branches;
│   │                           #   also checkProject, checkFile, didCloseFile, makeIdleFile
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
│   ├── nimcheck.nim            # nim check runner (nimCheck proc)
│   └── checking.nim            # checkProject helper, per-file check dispatch
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

**Import path convention**: all inter-module imports use relative paths from each file's own directory. There is no `nim_tools/` directory; that path prefix in some files is a stale WIP artifact that must be fixed. Correct paths:
- `../nimble/nimble` (not `../nim_tools/nimble/nimble`)
- `../nimsuggest/[suggestapi, nimsuggest_types]` (not `../nim_tools/nimsuggest/…`)
- `../nim_check/nimcheck` (not `../nim_tools/nimcheck/nimcheck`)
- `../nim_compiler/nim_compiler` (not `../nim_tools/compiler/nim_compiler`)

### `LanguageServer` type (current actual fields)

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
  checkInProgress*: bool
  isShutdown*:      bool
  nimDumpCache*:    Table[string, NimbleDumpInfo]
  cmdLineClientProcessId*: Option[int]
  testRunProcess*:  Option[AsyncProcessRef]
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

Defined in `src/langserver/langserver_types.nim`:

```nim
NlsFileInfo* = ref object of RootObj
  slot*:            NimsuggestSlot   # direct ref to pool slot; assigned in addFileToOpenFiles
  changed*:         bool             # unsaved edits exist; stash is authoritative
  fingerTable*:     seq[seq[tuple[u16pos, offset: int]]]  # UTF-8 → UTF-16 mapping
  cancelFileCheck*: Future[void]     # cancel token for deferred checkFile
  checkInProgress*: bool
  needsChecking*:   bool
  textDocument*:    TextDocumentItem
```

The old `projectFile: Future[string]` two-hop lookup is gone. The slot ref is
resolved synchronously during `addFileToOpenFiles` (in `dispatcher_utils.nim`) and stored
directly. **⚠ `slot` may be nil** if `didClose` fires for a URI whose `didOpen` has not
yet completed slot assignment (e.g. nimsuggest is still cold-compiling). Guard with
`if fileInfo.slot != nil:` before accessing `fileInfo.slot.queryMailbox` or calling
`fileInfo.slot.unassignUri`.

### `NimsuggestPool` and `NimsuggestSlot`

See `src/nimsuggest/nimsuggest_types.nim` for the authoritative type definitions.

```nim
NimsuggestPool* = ref object
  slots*: Table[string, NimsuggestSlot]   # projectFile → slot; all canonical (no aliases)
  maxSlots*: int                           # pool capacity; 0 = unlimited
  # Injected procs (set in initLanguageServer after construction):
  spawnProc*:        proc(projectFile: string, paths: seq[string]): Future[NimSuggest]
  stopProc*:         proc(ns: NimSuggest): Future[void]
  notifyProc*:       proc(meth: string, params: JsonNode)  # window/showMessage etc.
  statusChangedProc* proc()                                # ls.sendStatusChanged
```

Key points:
- `pool.slots` contains only canonical entries — no redirect alias pattern from the old architecture
- Each slot has a `queryMailbox: AsyncQueue[NimsuggestQuery]`; `processNimsuggestQueries` (in `nimsuggest_process.nim`) drains it and dispatches to TCP
- There is no separate `commandMailbox`; slot lifecycle (spawn/stop) is handled directly by callers
- `slot.crashCount` is incremented on `execSpawn` failure; after `MAX_CRASH_RETRIES` the slot gives up and notifies the user
- `execSpawn` backs off exponentially between retries (`1_000 * (1 shl crashCount)` ms, capped at 30s)

### The routing layer: `langserver/dispatcher.nim` + `dispatcher_utils.nim`

The old `requests/requests.nim` routing bridge is gone. LSP handlers enqueue work items
onto `ls.langserverQueue` as `LangserverQuery` objects. `processLangserverQueue` in
`dispatcher.nim` drains the queue in FIFO order:

- `LangserverQueryKind.NIMSUGGEST` → looks up `fileInfo.slot` and calls
  `slot.queryMailbox.addLastNoWait(q)`. This is the serialization point that ensures
  stash writes precede hover queries.
- `LangserverQueryKind.FILE_ACCESS` → executes the file operation inline (DID_OPEN,
  DID_CHANGE, DID_SAVE, DID_CLOSE, etc.)

`queryFile(ls, uri, kind)` in `dispatcher_utils.nim` is the convenience wrapper:
creates a `NimsuggestQuery`, enqueues it on `fileInfo.slot.queryMailbox`, returns the
`Future[seq[Suggest]]` to await. LSP handlers call this instead of `tryGetNimsuggest`.

### Async vs sync: the rule in this codebase

A proc must be `{.async.}` only if it has at least one `await`. Chronos's cooperative
scheduler makes sync procs implicitly atomic — nothing else can run between two
statements in a sync proc — which is a correctness property worth preserving.

**Currently sync** (de-asynced from the original):
- `addProjectFileToPendingRequest` — pure table mutation
- `didCloseFile` — uses `asyncSpawn ls.checkFile`, not `await`
- `makeIdleFile` — calls sync `didCloseFile`
- `addFileToOpenFiles` — stash write + table mutation + slot assignment
- `queryFile` — enqueue only, returns `Future[seq[Suggest]]` for caller to await

### Unknown-file routing — `dispatcher.nim` DID_OPEN branch

The old `warnIfUnknown` family is replaced by inline logic in `processLangserverQueue`'s
`DID_OPEN` branch (in `dispatcher.nim`). On open:

1. `isKnownByANimsuggestSlot(pool, uri)` — checks all live slots concurrently;
   returns the first slot that knows this file, or none.
2. If known → `addFileToOpenFiles(slot, textDocument)` — assign directly.
3. If unknown → determine `projectFile` via `getIntendedProject(ls, uri)` (projectMapping
   regex lookup, falling back to the file itself as orphan entry point).
4. If `pool.canSpawn` → create new `NimsuggestSlot`, `execSpawn`, then
   `asyncSpawn processNimsuggestQueries(slot, pool)`.
5. If pool at capacity → `nimsuggestSlotToEvict(pool)` (LRU among CRASHED→STOPPING→READY→SPAWNING),
   drain and clear its pending queries, `execStop`, then spawn new slot as in step 4.

> **⚠ Known bugs in the DID_OPEN branch (2026-08-07)**: (a) `execSpawn` is called with
> `await` inline in the queue drain coroutine, blocking all other queued items for the
> full cold-compile time (~11s). It must be offloaded via `asyncSpawn`. (b) After the
> async `isKnownByANimsuggestSlot` call, the newly created `newSlot` is not used in
> `addFileToOpenFiles` — the pre-spawn check result is passed instead. (c) No re-entry
> guard exists after the `await` returns; concurrent DID_OPENs for the same URI can
> assign split ownership. See `rewrite_analysis/2026-08-07_STATE_OF_THE_REPO.md` P0/P1.

### Software review fixes applied (2026-08-02)

From `rewrite_analysis/SOFTWARE_REVIEW.md`, all critical and significant issues are fixed:

| Issue | Fix location |
|---|---|
| `processQueries` stub — returned `@[]` for all queries | `nimsuggest/nimsuggest_process.nim` — full dispatch on `q.kind` |
| No crash recovery — crashed slot stayed dead | `nimsuggest/nimsuggest_slots.nim` `execSpawn` — retries up to `MAX_CRASH_RETRIES` |
| Nil pool startup race — `ls.pool` could be nil at first `didOpen` | `langserver/langserver.nim` — pool created in `initLanguageServer` |
| Evicted/idle slots not removed from pool — table grew unbounded | `langserver/dispatcher.nim` eviction branch + `nimsuggest_processes.nim` `idleSlots` |
| `makeStopProc` completed before process died — port collision on restart | `nimsuggest/nimsuggest_slots.nim` `execStop` — awaits `shutdownChildProcess` |
| Typo `LanguageServerCapabiities` | `langserver/langserver_types.nim`, `langserver/langserver.nim` |
| `params.mode.get()` panics if `none` | `langserver/langserver.nim` — `.get(ServerMode.lsp)`, `.get(TransportMode.stdio)` |
| Redundant `didOpenFile` forward declaration | removed |
| `getLspStatus` iterates `ns.openFiles` without snapshot | `langserver/langserver.nim` — `.toSeq` |
| `lruSlot` used `now()` as sentinel | `langserver/dispatcher_utils.nim` — `dateTime(9999, …)` |

### Bug fixes applied (2026-08-03)

These fixes resolved the SIGSEGV crash in `tests/tmisc.nim`:

| Issue | Root cause | Fix location |
|---|---|---|
| `tickLs` tail-recursion SIGSEGV | Each recursive `await ls.tickLs()` creates a new `Future` object. Under Nim 2.0.8's ORC, unbounded Future chains corrupt the heap allocator | `src/nimtortoise.nim` — changed to `while true` loop |
| `tick()` `withValue`+`del` use-after-pointer | `ls.files.openFiles.withValue(uri, info): ls.makeIdleFile(info[])` holds a raw pointer into the table's internal storage; `makeIdleFile` calls `openFiles.del(uri)` which invalidates it | `langserver/langserver.nim` — use plain `if uri in ...: let fileInfo = openFiles[uri]` |
| `tick()` STOP/evict ordering | `makeIdleFile` was called before STOP, so any spawned `checkFile` routed through a live-then-dying slot | `langserver/langserver.nim` — stop + `removeSlot` **before** evicting open files |
| `waitForNotification` tail-recursion | Same Future-chain accumulation as `tickLs` | `tests/lspsocketclient.nim` — changed to `while` loop |
| Nim version pinned to `== 2.0.8` | No documented reason; the exact pin prevented using Nim 2.2.x which has further ORC fixes | `nimtortoise.nimble` — changed to `>= 2.0.8` |

**Invariant**: any `{.async.}` proc that loops indefinitely must use `while true` + `await sleepAsync(...)`, never tail recursion (`await self()`). Each tail call in Nim async creates a new closure-backed `Future` object that is not freed until the entire chain resolves — which for an infinite loop means never.

### Production readiness fixes applied (2026-08-03)

Ten gaps identified by code review were fixed to make the rewrite production-ready.
Full rationale and implementation details are in `rewrite_analysis/PRODUCTION_READINESS_FIXES.md`.

| Fix | Problem | Files changed |
|---|---|---|
| A — Config wait timeout | `configReady.wait()` had no timeout; server could hang forever if VS Code never sent `workspace/configuration` | `langserver/configurations.nim`, `langserver/dispatcher.nim` |
| B — expand/expandAll bypass queue | Both handlers called `tryGetNimsuggest()` directly, skipping LRU tracking, crash detection, TCP serialization; `expandAll` also never used its result (always returned empty) | `nimsuggest/nimsuggest_types.nim`, `nimsuggest/nimsuggest_slots.nim`, `langserver/dispatcher_utils.nim`, handlers |
| C — Misleading TODO in `toInlayHint` | `# TODO: how to convert column?` suggested UTF-16 conversion was missing; it wasn't — callers already apply `toUtf16Pos` before calling the proc | handlers |
| D — Nimble exit code ignored in `tasks` | Non-zero exit silently returned empty task list with no user feedback | handlers |
| E — Stash write failure silent | `IOError` on stash write logged at `debug` level; nimsuggest would silently use stale disk content | `langserver/dispatcher_utils.nim` |
| F — Crash retry spin loop | No backoff between retries; persistent failures hammered the system at full speed | `nimsuggest/nimsuggest_slots.nim` |
| G — Permanent failure unhandled | After `MAX_CRASH_RETRIES`, slot stayed in pool (blocking future opens) with no user notification | `nimsuggest/nimsuggest_types.nim`, `nimsuggest/nimsuggest_slots.nim`, `langserver/langserver.nim` |
| H — isKnown timeout at debug level | Timeout/failure on `known` command was invisible in normal log output despite affecting routing decisions | `nimsuggest/nimsuggest_process.nim` |
| I — Error response missing method name | "Id not found in responseMap" log included only the id, not which RPC method was called | `langserver/langserver_types.nim`, `langserver/langserver.nim`, `langserver/transports.nim` |
| J — Sync `processContentLength` no error handling | `IOError` from `readLine()` in the stdio reader thread would crash the thread unhandled | `langserver/transports.nim` |

**Additional compile fixes found during test run** (not in the original review):
- `nimsuggest/nimsuggest_types.nim`: missing `json` import (needed for `NotifyProc` using `JsonNode`)
- `langserver/dispatcher_utils.nim`: `except IOError, OSError as ex:` is invalid Nim syntax; split into two clauses
- `nimsuggest/nimsuggest_slots.nim`: `sleepAsync(milliseconds(backoffMs))` used `TimeInterval` not `Duration`; fixed to `.millis`
- `nimsuggest/nimsuggest_slots.nim`: backoff `1 shl (crashCount - 1)` overflows when `crashCount == 0`; now guards `if slot.crashCount > 0`, shift capped at 14
- handlers: `createRangeFromSuggest` and `fixIdentation` were defined after their first use; moved before

### Bug fixes applied (2026-08-03, second session) — `tmonorepo.nim` / `tmaxlimits.nim`

These fixes resolved failures in the two new test files (`tmonorepo.nim`, `tmaxlimits.nim`).

| Issue | Root cause | Fix location |
|---|---|---|
| Config overwrite by `workspace/configuration` response | `fixhelpers.nim`'s `doInitialize` advertised `"workspace": {"configuration": true}`, causing the server to request config from client; client auto-responded with `[]`, overwriting test-set config (no `projectMapping`) before any `didOpen` | `tests/fixhelpers.nim` — removed `workspace.configuration` capability; `langserver/configurations.nim` — `maybeRequestConfigurationFromClient` else-branch now guards with `if ls.configurations.currentConfig.isNone` so test-set config is not overwritten |
| SPAWN never sent for pre-SPAWNING slots | `getOrCreateSlotForUri` sets `slot.state = SPAWNING` immediately to reserve capacity, but `didOpenFile`'s `if not slot.isActive:` guard evaluated to false (SPAWNING is active), so the SPAWN command was never sent | `langserver/dispatcher.nim` — changed guard to `if not slot.isActive or slot.ns.isNone:` so SPAWN is sent when state=SPAWNING but no actual spawn has started (`ns=none`) |
| Crash detection missing in `processNimsuggestQueries` | After nimsuggest crashes, `processQueue` in `suggestapi.nim` completes with `@[]` (no exception). `processNimsuggestQueries` had no code to detect the crash, so slots stayed READY forever | `nimsuggest/nimsuggest_process.nim` — added crash detection; transitions slot to CRASHED and triggers retry |
| Rename diagnostics clear only when file had prior errors | `didRenameFile` guarded `sendDiagnostics([], oldPath)` with `if oldPath in ls.files.filesWithDiags` | `langserver/dispatcher.nim` — removed guard; always send empty diagnostics on rename |
| `extension/statusUpdate` never sent after nimsuggest spawns | `sendStatusChanged` was only called from request start/end and `tick()`, not from spawn completion | `nimsuggest/nimsuggest_types.nim` — `statusChangedProc` field on `NimsuggestPool`; `langserver/langserver.nim` — wired to `ls.sendStatusChanged()`; `nimsuggest/nimsuggest_slots.nim` `execSpawn` — calls `pool.statusChangedProc()` on READY |

### Code review findings (2026-08-07)

Senior engineering assessment. Full details in `rewrite_analysis/2026-08-07_STATE_OF_THE_REPO.md`.

#### P0 — Compilation blockers (dispatcher.nim) — **RESOLVED**

These eight undefined-name errors in `dispatcher.nim` have been fixed and the code
now compiles. Listed here for historical reference:

| Location | Undefined name | Fix |
|---|---|---|
| Lines 71, 104 | `projectPath` | → `uri` |
| Lines 74, 107 | `s` | → `newSlot` |
| Lines 76, 109 | `pool` | → `ls.pool` |
| Lines 80, 113 | `processQueries` | → `processNimsuggestQueries` |
| Line 88 | `lruSlot` | → `slotToEvict` |
| Line 92 | `execStop` without `await` | Add `await` |
| Line 164 | `traceAsyncErrors` | Use `asyncSpawn` |
| Lines 79, 112 | `addFileToOpenFiles(fileIsKnown.get(), ...)` | Use `newSlot` (the spawned slot, not the pre-spawn check result) |

#### P1 — Runtime issues to fix next

- **Slot eviction mailbox drain race** (`dispatcher.nim` lines 86–92): futures completed
  with `@[]` while `processNimsuggestQueries` may be completing the same futures with
  real results — violates single-write invariant. Add `await` and snapshot length.
- **Stash path hash collision** (`dispatcher_utils.nim` line 57): `hash(uri).toHex`
  is collision-prone; two URIs with same hash silently corrupt each other's edit buffer.
  Replace with a collision-resistant key (monotonic counter or full URI as escaped path).
- **DID_OPEN blocks queue** (`dispatcher.nim`): `await execSpawn(...)` inline in the
  FIFO drain coroutine blocks all subsequent items for ~11s cold-compile time. Offload
  with `asyncSpawn`; assign slot to `openFiles` optimistically with pending state.
- **DID_OPEN re-entry race**: no guard after the `await isKnownByANimsuggestSlot`
  returns; concurrent opens for the same URI can split ownership between two slots.

#### P1 — Missing features (stub implementations)

- **`extension/macroExpand`** — stub; macro expansion completely unavailable.
- **`extension/suggest` (restart action)** — stub; no manual nimsuggest restart button.
- **`extension/status` / `extension/capabilities`** — stubs; VS Code status bar empty.
- **`checkFile`/`scheduleFileCheck` not wired** (`checking.nim` line 174 `# TODO CHECK FILE`):
  diagnostic squiggles update only on `didSave`, not during editing.
- **`didChangeConfiguration` incomplete** (`dispatcher.nim` line 286 `discard # TODO`):
  config changes to `nimsuggestIdleTimeout`, `projectMapping`, etc. are silently ignored.

#### P2 — Architecture concerns

- **`projectMapping` regex not cached**: `getIntendedProject` compiles regexes on every
  call; compile once at config load.
- **`workingDirectoryMapping` ignored**: `getWorkingDir()` is never called in the new
  dispatcher; needed for monorepo `config.nims` discovery (impacts cold-compile time).
- **Slot `STOPPING` state not set before idle `execStop`** (`langserver.nim` `tick()`):
  creates a window where `isActive` returns `true` while the process is shutting down.

#### What's working well in the rewrite

- Modular handler structure (`src/handlers/`) is much cleaner than the original `routes/lsp.nim`
- `while true` loops throughout (no tail recursion) — SIGSEGV fix correctly carried forward
- `NimsuggestSlot` explicit state enum is cleaner than the original's scattered booleans
- `crashedUris` per-slot (vs global `crashedFiles` table) is a better design
- `didSave` clearing crashed URIs is correctly implemented
- LRU eviction (`nimsuggestSlotToEvict`) is present and structurally correct
- `pool.slots` contains only canonical entries — no redirect alias pattern
- DID_OPEN correctly reuses an existing slot when `isKnown=false` (fix #22)

#### Recommended next actions (priority order)

1. Add nil guards for `fileInfo.slot` before use in `didClose`/`didSave` paths
2. Move `execSpawn` out of `processLangserverQueue` — use `asyncSpawn` (P1: queue blocks ~11s on cold compile)
3. Implement `extensionSuggest` with `saRestart` action (manual safety valve)
4. Wire `scheduleFileCheck` into DID_CHANGE
5. Fix stash key to be collision-resistant (replace `hash(uri).toHex` with monotonic counter or escaped URI)
6. Call `getWorkingDir()` when spawning nimsuggest
7. Cache compiled `projectMapping` regexes at config load time
8. Set slot state to `STOPPING` before `execStop` in `tick()`

---

### Module boundary intent

- `configurations/` — owns `NlsConfig` type and `parseWorkspaceConfiguration`; no LS dependency.
- `nimsuggest/nimsuggest_types.nim` — `NimsuggestQuery`, `NimsuggestSlot`, `NimsuggestPool` types.
- `nimsuggest/nimsuggest_slots.nim` — `execSpawn`, `execStop`; slot state machine.
- `nimsuggest/nimsuggest_process.nim` — `processNimsuggestQueries`, `runNimsuggestQuery`; TCP dispatch.
- `nimsuggest/suggestapi.nim` — `createNimsuggest`, raw TCP protocol (sug/def/hover/chk/…).
- `langserver/dispatcher.nim` — `processLangserverQueue` (FIFO queue drain), `checkProject`, `checkFile`, `didCloseFile`, `makeIdleFile`.
- `langserver/dispatcher_utils.nim` — `isKnownByANimsuggestSlot`, `addFileToOpenFiles`, `queryFile`, `nimsuggestSlotToEvict`.
- `langserver/nimsuggest_processes.nim` — `getIntendedProject`, `idleSlots`, `initNimsuggestInstances`, `stopNimsuggestProcesses`.
- `langserver/langserver.nim` — `initLanguageServer`, `tick`, `getLspStatus`, `nsCapabilities`, `nsProtocolVersion`, `getNimbleDumpInfo`.
- `handlers/` — LSP request/notification handlers; enqueue work onto `ls.langserverQueue`.
