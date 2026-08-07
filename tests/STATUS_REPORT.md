# tests_rewrite/ Status Report
_Generated 2026-08-03. Intended audience: an AI agent fixing failing tests._

---

## 1. Three-suite overview

The repository has three test suites that have existed at different points in time:

| Directory | Target architecture | Purpose |
|---|---|---|
| `tests/` | **Old** flat-file architecture (`ls.nim`, `nimlangserver.nim`, `lstransports.nim`) | Original integration test suite. Imports `../[nimlangserver, ls, lstransports]`. Cannot compile against the new `src/` layout. |
| `test_fixes/` | **New** `src/` architecture — already imports `../src/...` | Regression tests for bugs fixed in the `fix/maxnimsuggestlimits-clean` and `fix/nimsuggest-rename-recompile` branches. Written _during_ the rewrite; some suites are now outdated (see §4). |
| `tests_rewrite/` | **New** `src/` architecture | Ports of the original `tests/` integration tests, updated for the new API. These are the tests being actively developed. |

The primary goal of `tests_rewrite/` is to have the same _functional coverage_ as `tests/`, updated to the new API, so the rewrite branch can be validated without the old architecture.

---

## 2. Current test results (tests_rewrite/)

All results are from a fresh compile-and-run (`nim c --path:. -r <file>`).

| File | Suites | Tests | Result |
|---|---|---|---|
| `tsuggestapi.nim` | 2 | 8 | **PASSING** |
| `tnimlangserver.nim` | 4 | 14 | **PASSING** |
| `tprojectsetup.nim` | 2 | 3 | **PASSING** |
| `textensions.nim` | 1 | 7 | **PASSING** |
| `ttestrunner.nim` | 2 | 3 | **PASSING** |
| `tmisc.nim` | 3 | 3 | **FAILING** — see §3 |
| `tmcp.nim` | — | — | **Not run** — excluded from `all.nim`; requires separate entry point |

**Overall: 35/38 tests passing. 1 test failing (SIGSEGV crash). 1 file excluded.**

---

## 3. Failing test: tmisc.nim

### Suite map vs original

`tests/tmisc.nim` had **5 suites, 5 tests**. `tests_rewrite/tmisc.nim` has **3 suites, 3 tests**:

| Original suite / test | Status in rewrite |
|---|---|
| "Nimlangserver misc" / "after a period of inactivity, nimsuggest should be stopped" | **PORTED — FAILING (SIGSEGV)** |
| "Nimlangserver fail count" / "fail count is reset when a nimsuggest starts successfully" | **DROPPED** — `failCount` / `failTable` no longer exist; crash count lives on `NimsuggestSlot.crashCount` and is not accessible from the same test pattern |
| "Nimlangserver pending requests" / "cancelled projectFile future does not escape addProjectFileToPendingRequest" | **PORTED — PASSING** (simplified: the old test checked a cancelled Future; the new architecture uses a synchronous slot ref, so the test just checks `pendingRequests[id].projectFile`) |
| "Nimlangserver idle nimsuggest cleanup" / "idle nimsuggest is removed even when an open file was already evicted" | **PORTED — STATUS UNKNOWN** (the SIGSEGV in the first suite halts the process before this suite runs) |
| "Nimlangserver transport teardown" / "writeOutput drops writes after the stdio stream is torn down" | **PORTED — PASSING** |

### The SIGSEGV: what is known

The crash occurs in the **first test of the first suite** ("after a period of inactivity, nimsuggest should be stopped"). The test:

1. Starts a server via `main(cmdParams)`.
2. Fires `configReady` with `NlsConfig(nimsuggestIdleTimeout: some 1000)` (1 second).
3. Opens `hw.nim` via `textDocument/didOpen`.
4. Waits for `"Nimsuggest initialized for {hwAbsFile}"` notification.
5. Calls `asyncSpawn ls.tickLs()` to start the tick loop.
6. Waits for `"Nimsuggest for {hwAbsFile} was stopped because it was idle for too long"` notification.

The server log prints `"Removing idle nimsuggest"` before the crash, confirming that `tick()` ran and detected the idle slot. The crash then occurs inside `waitForNotificationMessage` in the test client — specifically in `rawAlloc → nimNewObj`, suggesting heap corruption or a use-after-free.

**Most likely root causes (in order of suspicion):**

1. **`slot.send SlotCommand(kind: STOP)` + `pool.removeSlot()` while `processCommands` coroutine is still running.** `removeSlot` deletes the slot from the pool table, but `processCommands` and `processQueries` coroutines hold a reference to the slot object. If a `checkFile` was in-flight (dispatched by `asyncSpawn ls.checkFile(uri)` in `didCloseFile`), it may try to access the slot after it has been stopped and the GC may have freed some sub-object.

2. **`tick()` calls `ls.makeIdleFile(info[])` via `withValue` while simultaneously `processCommands` is running STOP.** The `withValue` macro in Nim gives a pointer into the table's internal storage. If `makeIdleFile` internally calls `ls.files.openFiles.del(uri)` (which it likely does), this can invalidate the pointer `info[]` is accessing — use after free of an `NlsFileInfo` ref.

3. **`tickLs` recurses infinitely via `await ls.tickLs()`.** `tickLs` at `quicknimlsp.nim:212-215` is:
   ```nim
   proc tickLs*(ls: LanguageServer, time = 1.seconds) {.async.} =
     await ls.tick()
     await sleepAsync(time)
     await ls.tickLs()
   ```
   This is tail-recursive but NOT tail-call optimised in Nim. Every invocation creates a new stack frame and a new Future object. Under asyncdispatch (not Chronos), deep recursion accumulates closure objects on the heap. Combined with rapid GC pressure from a 1-second idle timeout in a hot test, this could cause heap corruption.

4. **`removeIdleNimsuggests()` in `nimsuggest.nim` sends STOP and calls `pool.removeSlot()` synchronously**, but the `processCommands` loop for that slot is still alive. The slot object has `commandMailbox: AsyncQueue` which may be freed before the coroutine sees the STOP command.

### What code to look at

Key files for this fix:

- `src/langserver/langserver.nim` — `tick()` proc (lines 355–373): iterates `idleSlots()`, calls `ls.makeIdleFile`, sends STOP, calls `pool.removeSlot`. This is where the heap corruption likely originates.
- `src/nimsuggest/nimsuggest.nim` — `idleSlots()` (lines 241–253) and `removeIdleNimsuggests()` (lines 255–266): the latter is called directly in the tmisc idle cleanup test.
- `src/langserver/files.nim` — `makeIdleFile`: needs to be checked to ensure it does not del from `openFiles` in a way that invalidates a `withValue` pointer.
- `tests_rewrite/tmisc.nim` line 78: `asyncSpawn ls.tickLs()` — this triggers the crash.

### Recommended fix approach

The fix should ensure that:
1. `pool.removeSlot(projectFile)` is NOT called from `tick()` or `removeIdleNimsuggests()` while `processCommands`/`processQueries` coroutines for that slot are still executing. The slot object must stay alive until its coroutines have exited.
2. `ls.makeIdleFile` must not be called inside a `withValue` block if `makeIdleFile` can call `openFiles.del(uri)` (which would invalidate the pointer). Extract the value first, then call `makeIdleFile`.
3. Consider making `tickLs` use a `while true` loop + `await sleepAsync` instead of tail recursion, to avoid unbounded Future accumulation.

---

## 4. tests_rewrite/ vs tests/ — what has been ported

### Ported (with API changes)

All the original `tests/*.nim` files except `tmcp.nim` have been ported to `tests_rewrite/`. The key API changes from the old to new architecture are documented at the top of each file. Summary:

| Old API | New API |
|---|---|
| `ls.workspaceConfiguration.complete(% @[conf])` | `ls.configurations.currentConfig = some(conf); ls.configurations.configReady.fire()` |
| `waitFor ls.workspaceConfiguration` | `waitFor ls.getAndWaitForWorkspaceConfiguration()` |
| `ls.openFiles.del(uri)` | `ls.files.openFiles.del(uri)` |
| `ls.projectFiles` | `ls.pool.slots` |
| `ls.failTable` | Removed. Crash count is `NimsuggestSlot.crashCount`. |
| `LanguageServer(serverMode: lsp, transportMode: stdio)` | `LanguageServer(capabilities: LanguageServerCapabilities(serverMode: lsp), transport: LanguageServerTransport(transportMode: stdio), ...)` — and requires `notify:` field to be set to avoid nil dereference |
| `ls.outStream` | `ls.transport.outStream` |
| `ls.pendingRequests` | `ls.messaging.pendingRequests` |
| `ls.projectFiles[hwAbsFile].process.pid` | `ls.pool.slots[hwAbsFile].resolvedNs.get.project.process.pid` |

### Not ported: tmcp.nim

`tests/tmcp.nim` has not been ported. The MCP server path in `src/routes/mcp.nim` exists but has not been tested. The file is excluded from `tests_rewrite/all.nim` with a comment.

---

## 5. test_fixes/ vs tests_rewrite/ — relationship and gap analysis

`test_fixes/` already imports from `../src/...` so it targets the new architecture. However, it was written against an intermediate state of the rewrite that no longer exactly matches the current code. Current status of each file:

### test_fixes/ files that need porting/updating for the new architecture

| File | Tests | Applicability to new architecture |
|---|---|---|
| `tmonorepo.nim` | 8 tests across 6 suites | **Partially applicable.** Tests fixes #7/#10/#11/#12/#13/#17/#18/#19 from the old `ls.nim`. Many of these concepts exist in the new architecture but the specific API (`ls.projectFiles`, `warnIfUnknown`, `crashedFiles`, `Project.errorCallback`) no longer exist. Would need significant rewriting to use `ls.pool.slots`, `NimsuggestSlot`, etc. **Not yet ported to tests_rewrite/.** |
| `tmaxlimits.nim` | 3 tests across 3 suites | **Partially applicable.** Tests checkFile ordering, maxNimsuggestProcesses enforcement, sentinel insertion. The concepts map to the new architecture but the implementation differs. **Not yet ported.** |
| `tbug1.nim` | 1 test | **Specific to old architecture's redirect alias bug.** New architecture uses `pool.slots` (no redirect aliases). The bug being tested cannot occur in the new design. **Not applicable; no port needed.** |
| `tbug2.nim` | 1 test | **Specific to old `warnIfUnknown` cross-project guard.** New architecture uses `routingPolicy` + `REDIRECT` decision in `processCommands`. Concept is testable but needs new test. **Not yet ported.** |
| `tbug3.nim` | 1 test | **KNOWN FAILING TEST** — documents a real bug ("assume-known-when-busy, no retry"). Applicable to new architecture: `execCheckKnown` has the same one-shot no-retry problem when `isKnown` times out. **Not yet ported; bug still exists.** |
| `tstab1.nim` | 8 tests | **Applicable** — stability tests that should work with new architecture. Not yet ported. |
| `tstab2.nim` | 3 tests | **Applicable** — stability tests. Not yet ported. |
| `tstab3.nim` | 2 tests | **Known to fail** due to Bug 3 (assume-known-when-busy). Not yet ported. |
| `tclassify_unknown.nim` | 30+ tests | **NOT APPLICABLE.** Tests `classifyUnknownFile` from old `ls.nim`, which does not exist in the new architecture. The new architecture uses `routingPolicy` in `src/langserver/queues.nim` instead. **Would need to be rewritten as unit tests for `routingPolicy`.** |
| `tls_unit.nim` | 5 tests | **Applicable** — unit tests for `findNimblePaths` in `src/nimble/nimble.nim`. Could be ported directly. Not yet in tests_rewrite/. |
| `tbugs.nim` | Superset of tbug1+2+3 | Old combined file. Superseded by the individual files. |

### Coverage gaps: what tests_rewrite/ is missing

The following test scenarios exist in `test_fixes/` or `tests/` but have **no equivalent in tests_rewrite/**:

1. **`routingPolicy` unit tests** — `tclassify_unknown.nim` has 30+ unit tests for `classifyUnknownFile`. The equivalent `routingPolicy` function in `src/langserver/queues.nim` is pure and unit-testable but has zero tests.

2. **`findNimblePaths` unit tests** — `tls_unit.nim` has 5 tests. Not ported.

3. **Idle nimsuggest cleanup when an open file was already evicted** — `tmisc.nim` suite 3 ("idle nimsuggest is removed even when an open file was already evicted"). Cannot be confirmed passing because the SIGSEGV in suite 1 halts the process.

4. **In-flight command completion on nimsuggest kill (fix #17)** — `tmonorepo.nim` "Fix #17" suite. The equivalent logic exists in `processQueries` completing futures with `@[]` on socket close, but there is no direct test of this in tests_rewrite/.

5. **projectMapping routing** (fix #8 / #18 / #19) — `tmaxlimits.nim` suite 2 and `tmonorepo.nim` suites 3-6. No equivalent in tests_rewrite/.

6. **`workspace/didRenameFiles`** (fix #7 / #11) — `tmonorepo.nim` suite 4. No equivalent in tests_rewrite/.

7. **MCP protocol** — `tests/tmcp.nim`. Not ported.

---

## 6. Source files for fixes

For an agent fixing the `tmisc.nim` SIGSEGV, the relevant files are:

```
src/quicknimlsp.nim          — tickLs proc (lines 212-215, recursive async)
src/langserver/langserver.nim — tick() proc (lines 355-373)
src/nimsuggest/nimsuggest.nim — idleSlots() (241-253), removeIdleNimsuggests() (255-266)
src/langserver/files.nim     — makeIdleFile proc
src/langserver/queues.nim    — execStop (278-296), processCommands (391-433)
tests_rewrite/tmisc.nim      — the failing test (lines 50-80)
```

The `NimsuggestSlot` type is in `src/langserver/queue_types.nim` (lines 197-230).

The `NimsuggestPool.removeSlot` is in `src/langserver/queues.nim` (line 196-197):
```nim
proc removeSlot*(pool: NimsuggestPool, projectFile: string) =
  pool.slots.del(projectFile)
```

This immediately removes the slot from the table, but `processCommands` and `processQueries` coroutines still hold a ref to the slot object and are still running. The slot's `commandMailbox` and `queryMailbox` (AsyncQueues) are still being accessed by these coroutines. If GC collects sub-objects after the table entry is deleted (because the table was the last strong reference keeping something alive), corruption ensues.
