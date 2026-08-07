# tmisc.nim crash investigation notes

## Test: "after a period of inactivity, nimsuggest should be stopped"

**Symptom**: SIGSEGV in `rawAlloc` → `nimNewObj` inside `waitForNotificationMessage`
at `lspsocketclient.nim:206`, triggered right after "Removing idle nimsuggest" is logged.

**What works**: The tick correctly detects the idle slot and fires `ls.notify(window/showMessage, "...was stopped...")`. The "Removing idle nimsuggest" log appears.

**Likely causes**:

1. **`asyncSpawn ls.checkFile(uri)` inside `didCloseFile`**: When `tick()` calls
   `makeIdleFile` → `didCloseFile`, if `fileInfo.changed` is true, a `checkFile`
   coroutine is spawned. `checkFile` awaits `queryFile` → routes through the slot.
   But the slot is stopped (`slot.send STOP`) immediately after `makeIdleFile` returns.
   The spawned coroutine resumes into a dead/freed slot object, corrupting the heap.
   hw.nim is opened via `didOpen` so `changed=false` initially, but the `didSave`
   path in the full server might set it during nimsuggest init.

2. **`withValue` pointer invalidated by `del`**: `tick()` calls
   `ls.files.openFiles.withValue(uri, info): ls.makeIdleFile(info[])`.
   Inside `makeIdleFile`, `didCloseFile` calls `ls.files.openFiles.del(uri)`.
   Even though `NlsFileInfo` is a `ref` (heap-stable), `info` is a `ptr NlsFileInfo`
   into the table's internal storage. After `del`, that pointer is dangling. The
   `file` parameter of `makeIdleFile` captures `info[]` before the del, but if
   the compiler doesn't copy the ref before the del fires, ARC could free it.

3. **Slot lifetime**: `slot.send SlotCommand(kind: STOP)` after `removeSlot` removes
   the slot from `pool.slots`. But the slot object itself lives on in its coroutines
   (`processCommands`/`processQueries`). If those coroutines touch freed memory
   after the event loop resumes during `waitFor sleepAsync(100)`, heap corruption
   follows. The concurrent `tickLs` re-entrant tick could also race with cleanup.

4. **Recursive `waitForNotification` chain**: 10s timeout / 100ms per step = 100
   levels of future-chain. The crash in `nimNewObj` might be the 101st allocation
   hitting a corrupted allocator state left by one of the above.

## Suggested fixes to investigate

- Guard `asyncSpawn ls.checkFile(uri)` in `didCloseFile` — don't spawn if the
  slot is about to be stopped (i.e., caller is `makeIdleFile`). Could add an
  `isIdling: bool` parameter to suppress the checkFile spawn.
- Use `let fileRef = ls.files.openFiles[uri]` to capture the ref BEFORE calling
  `makeIdleFile`, so the pointer isn't used after the del.
- Stop the slot BEFORE calling `makeIdleFile` (so `checkFile` routes to a dead slot
  and gets `@[]` rather than corrupting a live one).
- In `tick()`, send STOP to the slot first, then call `makeIdleFile` after, so any
  spawned `checkFile` hits the already-stopped slot (which returns `@[]` cleanly).
