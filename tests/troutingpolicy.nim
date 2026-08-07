## troutingpolicy.nim
## Unit tests for routingPolicy in src/langserver/queues.nim.
##
## routingPolicy is a pure function (no I/O, no async, no running server).
## Tests construct NimsuggestPool / NimsuggestSlot directly and assert the
## returned RoutingResult.decision and, where relevant, targetProjectFile /
## evictSlot.
##
## Mapping from old classifyUnknownFile WarnActions to new RoutingDecision values:
##   waNoAction              → ACCEPT
##   waRestartForIntended    → SPAWN_ALONGSIDE / EVICT_AND_SPAWN (intended target)
##   waGuardSkip (intended)  → REDIRECT
##   waGuardSkip (standalone)→ ACCEPT  (slot already running for that file)
##   waSpawnAlongside        → SPAWN_ALONGSIDE
##   waKillAndReplace        → EVICT_AND_SPAWN
##   waCascadePrevention     → no equivalent (handled at processCommands level)
##   waShowWarning           → NO_CAPACITY (pool full, all slots are entry points)
##
## Run with: nim c --path:. -r tests_rewrite/troutingpolicy.nim

import ../src/langserver/[queues, queue_types, utils]
import ../src/nimsuggest/nimsuggest_types
import std/[options, tables, sets]
import unittest2

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makePool(maxSlots: int): NimsuggestPool =
  ## Minimal pool for policy tests. spawnProc/stopProc/isKnownProc are nil
  ## because routingPolicy never calls them — it is a pure decision function.
  NimsuggestPool(
    slots: initTable[string, NimsuggestSlot](),
    maxSlots: maxSlots,
  )

proc addActiveSlot(pool: NimsuggestPool, projectFile: string, isEntryPoint = false): NimsuggestSlot =
  ## Create a READY slot, add it to the pool, and return it.
  let s = newSlot(projectFile, isEntryPoint)
  s.state = SlotState.READY
  pool.addSlot(s)
  s

proc addSpawningSlot(pool: NimsuggestPool, projectFile: string): NimsuggestSlot =
  ## Create a SPAWNING slot (counts toward active / maxSlots).
  let s = newSlot(projectFile)
  s.state = SlotState.SPAWNING
  pool.addSlot(s)
  s

proc assignedSlot(pool: NimsuggestPool, projectFile: string, isEntryPoint = false): NimsuggestSlot =
  ## Convenience: ensure a READY slot exists in the pool for projectFile and return it.
  if projectFile in pool.slots:
    return pool.slots[projectFile]
  pool.addActiveSlot(projectFile, isEntryPoint)

proc fileUri(path: string): string =
  pathToUri(path)

# ===========================================================================
# Suite 1: isKnown = true → ACCEPT
# ===========================================================================

suite "routingPolicy — file is known (ACCEPT)":

  test "basic: file known to assigned slot, no action needed":
    ## Normal use: the file is already in nimsuggest's module graph.
    ## Hover, completions, goto-definition all work. Nothing to do.
    let pool = makePool(1)
    let slot = pool.assignedSlot("/project/src/myproject.nim")
    let result = routingPolicy(
      isKnown = true,
      uri = fileUri("/project/src/models.nim"),
      intendedProjectFile = "",
      assignedSlot = slot,
      pool = pool,
    )
    check result.decision == RoutingDecision.ACCEPT

  test "isKnown=true dominates even when cross-project params suggest a restart":
    ## The file is assigned to a reused nimsuggest from a different project, but
    ## nimsuggest already knows it (shared import). No restart needed.
    let pool = makePool(1)
    let slot = pool.assignedSlot("/project/projectA/src/a.nim")
    let result = routingPolicy(
      isKnown = true,
      uri = fileUri("/project/projectB/src/b.nim"),
      intendedProjectFile = "/project/projectB/src/b.nim",
      assignedSlot = slot,
      pool = pool,
    )
    check result.decision == RoutingDecision.ACCEPT

  test "isKnown=true dominates when standalone slot would otherwise be spawned":
    ## File turned out known despite pool having capacity for a standalone spawn.
    let pool = makePool(2)
    let slot = pool.assignedSlot("/project/src/myproject.nim")
    let result = routingPolicy(
      isKnown = true,
      uri = fileUri("/project/src/orphan.nim"),
      intendedProjectFile = "",
      assignedSlot = slot,
      pool = pool,
    )
    check result.decision == RoutingDecision.ACCEPT

# ===========================================================================
# Suite 2: Cross-project branch
# Entered when: intendedProjectFile != "" AND intendedProjectFile != assignedSlot.projectFile
# ===========================================================================

suite "routingPolicy — cross-project branch":

  test "intended project already has a live slot → REDIRECT":
    ## User switches to a file in project B. With maxNs=1, project A's nimsuggest
    ## was reused. Project B's nimsuggest has since been started by another file.
    ## Redirect this URI to the already-running intended slot.
    let pool = makePool(2)
    let assignedS = pool.assignedSlot("/project/pkga/src/pkga.nim")
    discard pool.addActiveSlot("/project/pkgb/src/pkgb.nim")  # intended is live
    let result = routingPolicy(
      isKnown = false,
      uri = fileUri("/project/pkgb/src/util.nim"),
      intendedProjectFile = "/project/pkgb/src/pkgb.nim",
      assignedSlot = assignedS,
      pool = pool,
    )
    check result.decision == RoutingDecision.REDIRECT
    check result.targetProjectFile == "/project/pkgb/src/pkgb.nim"

  test "intended project not running, pool has capacity → SPAWN_ALONGSIDE for intended":
    ## User switches to api_products.nim (project B). No nimsuggest for B yet.
    ## A free slot exists. Spawn project B alongside project A.
    let pool = makePool(2)
    let assignedS = pool.assignedSlot("/project/pkga/src/pkga.nim")
    let result = routingPolicy(
      isKnown = false,
      uri = fileUri("/project/pkgb/src/api_products.nim"),
      intendedProjectFile = "/project/pkgb/src/pkgb.nim",
      assignedSlot = assignedS,
      pool = pool,
    )
    check result.decision == RoutingDecision.SPAWN_ALONGSIDE
    check result.targetProjectFile == "/project/pkgb/src/pkgb.nim"

  test "intended project not running, pool full, LRU available → EVICT_AND_SPAWN for intended":
    ## maxNs=1. Project A's slot is full and is the LRU. Evict A, spawn B.
    let pool = makePool(1)
    let assignedS = pool.assignedSlot("/project/pkga/src/pkga.nim")
    let result = routingPolicy(
      isKnown = false,
      uri = fileUri("/project/pkgb/src/api_products.nim"),
      intendedProjectFile = "/project/pkgb/src/pkgb.nim",
      assignedSlot = assignedS,
      pool = pool,
    )
    check result.decision == RoutingDecision.EVICT_AND_SPAWN
    check result.targetProjectFile == "/project/pkgb/src/pkgb.nim"
    check result.evictSlot == "/project/pkga/src/pkga.nim"

  test "intended not running, pool full, all entry points → NO_CAPACITY":
    ## All pool slots are marked isEntryPoint (nimble dump discovered them).
    ## No slot can be evicted. Cannot serve the cross-project file.
    let pool = makePool(1)
    let assignedS = pool.assignedSlot("/project/pkga/src/pkga.nim", isEntryPoint = true)
    let result = routingPolicy(
      isKnown = false,
      uri = fileUri("/project/pkgb/src/api_products.nim"),
      intendedProjectFile = "/project/pkgb/src/pkgb.nim",
      assignedSlot = assignedS,
      pool = pool,
    )
    check result.decision == RoutingDecision.NO_CAPACITY

  test "intendedProjectFile == assignedSlot.projectFile → falls to standalone path":
    ## No forced-reuse occurred. The file's intended project IS the assigned one.
    ## The file is simply unimported. Falls to standalone branch, not cross-project.
    ## With capacity, spawns standalone for the file itself.
    let pool = makePool(2)
    let assignedS = pool.assignedSlot("/project/src/myproject.nim")
    let filePath = "/project/src/orphan.nim"
    let result = routingPolicy(
      isKnown = false,
      uri = fileUri(filePath),
      intendedProjectFile = "/project/src/myproject.nim",  # same as assigned
      assignedSlot = assignedS,
      pool = pool,
    )
    check result.decision == RoutingDecision.SPAWN_ALONGSIDE
    check result.targetProjectFile == filePath

  test "intendedProjectFile == '' → falls to standalone path":
    ## No projectMapping matched this file. Falls to standalone branch.
    let pool = makePool(2)
    let assignedS = pool.assignedSlot("/project/src/myproject.nim")
    let filePath = "/project/src/orphan.nim"
    let result = routingPolicy(
      isKnown = false,
      uri = fileUri(filePath),
      intendedProjectFile = "",
      assignedSlot = assignedS,
      pool = pool,
    )
    check result.decision == RoutingDecision.SPAWN_ALONGSIDE
    check result.targetProjectFile == filePath

# ===========================================================================
# Suite 3: Standalone branch
# Entered when: intendedProjectFile == "" or == assignedSlot.projectFile
# ===========================================================================

suite "routingPolicy — standalone branch":

  test "standalone slot already active for this file → ACCEPT":
    ## The user re-opens a file that already has a standalone nimsuggest running
    ## (spawned on the first open). No second process needed.
    let pool = makePool(2)
    let assignedS = pool.assignedSlot("/project/src/myproject.nim")
    let filePath = "/project/src/orphan.nim"
    discard pool.addActiveSlot(filePath)  # standalone slot already live
    let result = routingPolicy(
      isKnown = false,
      uri = fileUri(filePath),
      intendedProjectFile = "",
      assignedSlot = assignedS,
      pool = pool,
    )
    check result.decision == RoutingDecision.ACCEPT

  test "standalone slot SPAWNING (not yet READY) → still ACCEPT":
    ## A standalone spawn is already in progress for this file. Sending a second
    ## SPAWN would create a duplicate process. SPAWNING counts as active → ACCEPT.
    let pool = makePool(2)
    let assignedS = pool.assignedSlot("/project/src/myproject.nim")
    let filePath = "/project/src/orphan.nim"
    discard pool.addSpawningSlot(filePath)
    let result = routingPolicy(
      isKnown = false,
      uri = fileUri(filePath),
      intendedProjectFile = "",
      assignedSlot = assignedS,
      pool = pool,
    )
    check result.decision == RoutingDecision.ACCEPT

  test "pool has a free slot, no standalone yet → SPAWN_ALONGSIDE for file itself":
    ## maxNs=2 and only one slot in use. Spawn a second nimsuggest for this
    ## unimported file without disturbing the first.
    let pool = makePool(2)
    let assignedS = pool.assignedSlot("/project/src/myproject.nim")
    let filePath = "/project/src/new_module.nim"
    let result = routingPolicy(
      isKnown = false,
      uri = fileUri(filePath),
      intendedProjectFile = "",
      assignedSlot = assignedS,
      pool = pool,
    )
    check result.decision == RoutingDecision.SPAWN_ALONGSIDE
    check result.targetProjectFile == filePath

  test "pool full, LRU slot available → EVICT_AND_SPAWN for file":
    ## maxNs=1. The only slot is the assigned project. Evict it, start standalone.
    let pool = makePool(1)
    let assignedS = pool.assignedSlot("/project/src/myproject.nim")
    let filePath = "/project/src/orphan.nim"
    let result = routingPolicy(
      isKnown = false,
      uri = fileUri(filePath),
      intendedProjectFile = "",
      assignedSlot = assignedS,
      pool = pool,
    )
    check result.decision == RoutingDecision.EVICT_AND_SPAWN
    check result.targetProjectFile == filePath
    check result.evictSlot == "/project/src/myproject.nim"

  test "pool full, all slots are entry points → NO_CAPACITY":
    ## All slots are protected (nimble discovered them). Cannot evict. File gets
    ## no IDE features. The caller should warn the user.
    let pool = makePool(1)
    let assignedS = pool.assignedSlot("/project/src/myproject.nim", isEntryPoint = true)
    let filePath = "/project/src/orphan.nim"
    let result = routingPolicy(
      isKnown = false,
      uri = fileUri(filePath),
      intendedProjectFile = "",
      assignedSlot = assignedS,
      pool = pool,
    )
    check result.decision == RoutingDecision.NO_CAPACITY

# ===========================================================================
# Suite 4: LRU eviction target selection
# ===========================================================================

suite "routingPolicy — LRU eviction target":

  test "evicts the non-entry-point slot, not the entry-point slot":
    ## Pool has two slots at maxSlots=2: one entry-point (protected) and one
    ## regular. When eviction is needed, the regular slot must be chosen.
    let pool = makePool(2)
    let ep = pool.assignedSlot("/project/src/myproject.nim", isEntryPoint = true)
    let lru = pool.addActiveSlot("/project/src/widget.nim", isEntryPoint = false)
    let filePath = "/project/src/orphan.nim"
    let result = routingPolicy(
      isKnown = false,
      uri = fileUri(filePath),
      intendedProjectFile = "",
      assignedSlot = ep,
      pool = pool,
    )
    check result.decision == RoutingDecision.EVICT_AND_SPAWN
    check result.evictSlot == "/project/src/widget.nim"
    check result.targetProjectFile == filePath

  test "cross-project eviction also picks the LRU non-entry slot":
    ## At maxSlots=2, with one entry-point and one regular slot. Cross-project
    ## redirect needed. The regular slot is the eviction candidate.
    let pool = makePool(2)
    let ep = pool.assignedSlot("/project/src/myproject.nim", isEntryPoint = true)
    discard pool.addActiveSlot("/project/src/widget.nim", isEntryPoint = false)
    let filePath = "/project/pkgb/src/b.nim"
    let result = routingPolicy(
      isKnown = false,
      uri = fileUri("/project/pkgb/src/util.nim"),
      intendedProjectFile = filePath,
      assignedSlot = ep,
      pool = pool,
    )
    check result.decision == RoutingDecision.EVICT_AND_SPAWN
    check result.evictSlot == "/project/src/widget.nim"
    check result.targetProjectFile == filePath
