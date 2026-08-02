## tclassify_unknown.nim
##
## Unit tests for classifyUnknownFile.
##
## No running nimsuggest, no LanguageServer, no async runtime required.
## Each test constructs a WarnContext literal and asserts the resulting WarnAction.
##
## Test matrix covers every meaningful branch combination of the 9 input fields.
## Each test includes a plain-English user scenario: the editor action that would
## produce this exact context, and what would happen to the user if the wrong
## action were returned.
##
## Run with: nim c -r test_fixes/tclassify_unknown.nim

import unittest2
import ../warn_if_unknown_alt

# ---------------------------------------------------------------------------
# Helper — base context with safe defaults, overridden per test
# ---------------------------------------------------------------------------
# Defaults represent the most common production state:
# a standalone, capable nimsuggest at the process limit with no special conditions.

func ctx(
    path = "src/foo.nim",
    projectFile = "src/myproject.nim",
    intendedProjectFile = "",
    isKnown = false,
    canHandleUnknown = true,
    canSpawn = false,
    intendedAlreadyRunning = false,
    standaloneAlreadyRunning = false,
    isRedirectAlias = false,
    pathIsProjectEntryFile = false,
): WarnContext =
  WarnContext(
    path: path,
    projectFile: projectFile,
    intendedProjectFile: intendedProjectFile,
    isKnown: isKnown,
    canHandleUnknown: canHandleUnknown,
    canSpawn: canSpawn,
    intendedAlreadyRunning: intendedAlreadyRunning,
    standaloneAlreadyRunning: standaloneAlreadyRunning,
    isRedirectAlias: isRedirectAlias,
    pathIsProjectEntryFile: pathIsProjectEntryFile,
  )

# ===========================================================================
# Suite 1: isKnown = true → waNoAction
#
# isKnown is the first check. When true, every other field is irrelevant.
# ===========================================================================

suite "classifyUnknownFile — file is known (waNoAction)":

  test "basic: file is in nimsuggest module graph, no action needed":
    ## The user opens models.nim, which is imported by myproject.nim.
    ## Nimsuggest already compiled it at startup. Hover, goto-definition,
    ## and completions all work immediately. Nothing to do.
    check classifyUnknownFile(ctx(isKnown = true)) == waNoAction

  test "isKnown=true dominates even when cross-project params suggest a restart":
    ## The user has maxNimsuggestProcesses=1. The file is assigned to a reused
    ## nimsuggest from a different project — but nimsuggest already knows it
    ## (perhaps via a shared import). No restart needed despite the mismatch.
    check classifyUnknownFile(ctx(
      isKnown = true,
      intendedProjectFile = "other/intended.nim",
      intendedAlreadyRunning = false,
    )) == waNoAction

  test "isKnown=true dominates even when standalone params suggest a spawn":
    ## The user opens an unimported file and a free slot is available — but
    ## the file turned out to already be known (nimsuggest compiled it as a
    ## transitive import). No spawn needed.
    check classifyUnknownFile(ctx(
      isKnown = true,
      canSpawn = true,
      isRedirectAlias = true,
    )) == waNoAction

# ===========================================================================
# Suite 2: Cross-project branch
#
# Entered when: intendedProjectFile != "" AND intendedProjectFile != projectFile.
# This happens when maxNimsuggestProcesses forced reuse of an existing nimsuggest
# that belongs to a different project than the one the regex mapping intended.
# canHandleUnknown, standaloneAlreadyRunning, canSpawn, isRedirectAlias are all
# irrelevant in this branch.
# ===========================================================================

suite "classifyUnknownFile — cross-project branch":

  test "intended project has no running nimsuggest → waRestartForIntended":
    ## The user switches from editing project A files to api_products.nim in
    ## project B. With maxNimsuggestProcesses=1, the langserver reused project
    ## A's nimsuggest slot. api_products.nim isn't in project A's module graph.
    ## The correct fix is to restart nimsuggest for project B.
    check classifyUnknownFile(ctx(
      intendedProjectFile = "api/api.nim",
      intendedAlreadyRunning = false,
    )) == waRestartForIntended

  test "intended project already has a live nimsuggest → waGuardSkip":
    ## The user opens api_routes.nim (project B), triggering a restart for B.
    ## While that restart is completing, they open api_products.nim (also project B).
    ## The guard fires: project B's nimsuggest is already starting or running.
    ## Restarting again would kill the in-progress compile — skip.
    check classifyUnknownFile(ctx(
      intendedProjectFile = "api/api.nim",
      intendedAlreadyRunning = true,
    )) == waGuardSkip

  test "canSpawn=true is irrelevant in the cross-project branch → waRestartForIntended":
    ## A free slot exists, but the cross-project branch always restarts for the
    ## intended project regardless. Spawning a separate nimsuggest for the current
    ## (wrong) project would leave the file permanently unresolved.
    check classifyUnknownFile(ctx(
      intendedProjectFile = "api/api.nim",
      intendedAlreadyRunning = false,
      canSpawn = true,
    )) == waRestartForIntended

  test "intendedProjectFile='' → not the cross-project branch, falls to standalone":
    ## No projectMapping regex matched this file. There is no 'intended' project —
    ## the file simply has no known project membership. Falls through to the
    ## standalone/warning branch, not the cross-project restart.
    check classifyUnknownFile(ctx(
      intendedProjectFile = "",
      canHandleUnknown = false,
    )) == waShowWarning

  test "intendedProjectFile=projectFile → not the cross-project branch, falls to standalone":
    ## The regex mapping matched, but the intended project IS the currently assigned
    ## one (no forced reuse occurred). The file is genuinely unimported by its own
    ## project. Falls to the standalone branch.
    check classifyUnknownFile(ctx(
      projectFile = "src/myproject.nim",
      intendedProjectFile = "src/myproject.nim",
      canHandleUnknown = false,
    )) == waShowWarning

# ===========================================================================
# Suite 3: Standalone branch — canHandleUnknown = false → waShowWarning
#
# Entered when: file is unknown AND not in the cross-project branch.
# canHandleUnknown=false means this nimsuggest cannot compile files in isolation
# at all. The only action is a user-visible warning.
# canSpawn and isRedirectAlias are irrelevant when canHandleUnknown=false.
# ===========================================================================

suite "classifyUnknownFile — standalone, no unknownFile capability (waShowWarning)":

  test "no regex match, old nimsuggest → user sees warning message":
    ## The user opens a utility file that isn't imported anywhere. Their nimsuggest
    ## version is too old to support the unknownFile capability. They see:
    ## "foo.nim is not compiled as part of project myproject.nim. You must either
    ## configure nim.projectMapping or import the module."
    ## Without this warning, the user would have no IDE features and no explanation.
    check classifyUnknownFile(ctx(
      intendedProjectFile = "",
      canHandleUnknown = false,
    )) == waShowWarning

  test "file is unimported by its own project, old nimsuggest → waShowWarning":
    ## The user writes a new module in their project folder but hasn't added an
    ## import for it yet. intendedProjectFile=projectFile (no forced reuse).
    ## Because canHandleUnknown=false, even a free slot wouldn't help.
    check classifyUnknownFile(ctx(
      projectFile = "src/myproject.nim",
      intendedProjectFile = "src/myproject.nim",
      canHandleUnknown = false,
    )) == waShowWarning

  test "canSpawn=true does not bypass the warning when canHandleUnknown=false":
    ## A free nimsuggest slot is available, but that doesn't matter: an incapable
    ## nimsuggest spawned for this file still cannot compile it in isolation.
    ## Spawning would give the user a nimsuggest process that immediately fails —
    ## worse than just warning them.
    check classifyUnknownFile(ctx(
      canHandleUnknown = false,
      canSpawn = true,
    )) == waShowWarning

# ===========================================================================
# Suite 4: Standalone capable, already running → waGuardSkip
#
# Entered when: canHandleUnknown=true AND standaloneAlreadyRunning=true.
# A nimsuggest is already running with THIS file as its own entry point.
# Spawning another would create a duplicate process. canSpawn is irrelevant here.
# ===========================================================================

suite "classifyUnknownFile — standalone already running (waGuardSkip)":

  test "standalone nimsuggest already live, at limit → waGuardSkip":
    ## The user opens fraction_layouts.nim. A standalone nimsuggest was spawned
    ## for it on the previous open and has since finished compiling. The user
    ## closed and re-opened the file. The guard prevents killing the healthy
    ## standalone process and restarting it for no reason.
    check classifyUnknownFile(ctx(
      standaloneAlreadyRunning = true,
      canSpawn = false,
    )) == waGuardSkip

  test "standalone already live, free slot exists → still waGuardSkip":
    ## Same as above but with maxNimsuggestProcesses=2. canSpawn=true does not
    ## override the guard: we already have the right nimsuggest running for this
    ## file. Spawning a second one alongside would waste a slot.
    check classifyUnknownFile(ctx(
      standaloneAlreadyRunning = true,
      canSpawn = true,
    )) == waGuardSkip

# ===========================================================================
# Suite 5: Spawn alongside — canSpawn = true
#
# Entered when: canHandleUnknown=true, standaloneAlreadyRunning=false, canSpawn=true.
# A free slot exists. Start a second nimsuggest for this file without disturbing
# the existing one. isRedirectAlias is only checked when canSpawn=false — irrelevant here.
# ===========================================================================

suite "classifyUnknownFile — spawn alongside (waSpawnAlongside)":

  test "free slot available, no standalone yet → waSpawnAlongside":
    ## The user has maxNimsuggestProcesses=2. They open fraction_layouts.nim,
    ## which isn't imported by user_interfaces.nim. A slot is free. A second
    ## nimsuggest starts for fraction_layouts.nim without touching the first.
    ## Both files now have full IDE features simultaneously.
    check classifyUnknownFile(ctx(
      canSpawn = true,
      isRedirectAlias = false,
    )) == waSpawnAlongside

  test "free slot available, redirect alias present → still waSpawnAlongside":
    ## isRedirectAlias is only consulted in the kill-and-replace path (canSpawn=false).
    ## When a slot is free we always spawn alongside regardless of alias state.
    ## Checking isRedirectAlias here would be a category error.
    check classifyUnknownFile(ctx(
      canSpawn = true,
      isRedirectAlias = true,
    )) == waSpawnAlongside

# ===========================================================================
# Suite 6: Kill and replace / cascade prevention
#
# Entered when: canHandleUnknown=true, standaloneAlreadyRunning=false, canSpawn=false.
# At the process limit. Decision point: cascade prevention or proceed?
# ===========================================================================

suite "classifyUnknownFile — kill and replace / cascade (waKillAndReplace / waCascadePrevention)":

  test "at limit, no redirect alias → waKillAndReplace":
    ## The user opens fraction_layouts.nim. Only one nimsuggest slot and it's
    ## currently serving user_interfaces.nim. No redirect alias yet — this is
    ## the first unimported file to trigger a standalone restart this session.
    ## Kill user_interfaces.nim's nimsuggest, start a fresh one for fraction_layouts.nim.
    check classifyUnknownFile(ctx(
      canSpawn = false,
      isRedirectAlias = false,
    )) == waKillAndReplace

  test "at limit, redirect alias, path != projectFile → waCascadePrevention":
    ## fraction_layouts.nim just triggered a kill-and-replace. The slot now holds
    ## a redirect alias (.file=fraction_layouts). proportion_tree_left.nim fires
    ## warnIfUnknown and sees the alias. If it proceeded, it would kill the
    ## just-started fraction_layouts nimsuggest — neither file would ever stabilise.
    ## Bail to prevent the cascade.
    check classifyUnknownFile(ctx(
      path = "proportion_tree_left.nim",
      projectFile = "user_interfaces.nim",
      canSpawn = false,
      isRedirectAlias = true,
      pathIsProjectEntryFile = false,
    )) == waCascadePrevention

  test "at limit, redirect alias, path == projectFile → waKillAndReplace (escape hatch)":
    ## The user switches editor focus back to user_interfaces.nim (the project
    ## entry-file) while a redirect alias is present from a previous standalone
    ## restart. This is a deliberate "take back" — the user wants their project's
    ## nimsuggest slot returned to the entry-file. Cascade prevention must NOT
    ## fire here: pathIsProjectEntryFile=true is the escape hatch.
    ## Without this fix, classifyUnknownFile returned waCascadePrevention and the
    ## user's entry-file was permanently stuck with no IDE features until restart.
    check classifyUnknownFile(ctx(
      path = "user_interfaces.nim",
      projectFile = "user_interfaces.nim",
      canSpawn = false,
      isRedirectAlias = true,
      pathIsProjectEntryFile = true,
    )) == waKillAndReplace

# ===========================================================================
# Suite 7: Branch priority — earlier branches dominate later ones
#
# Verifies that the order of checks in classifyUnknownFile is correct:
# canHandleUnknown=false fires before the cascade check is ever reached.
# ===========================================================================

suite "classifyUnknownFile — branch priority":

  test "canHandleUnknown=false fires before cascade check → waShowWarning not waCascadePrevention":
    ## The user has an old nimsuggest. A redirect alias is present. If the cascade
    ## check ran first, the function would return waCascadePrevention — silently
    ## doing nothing. Instead, the canHandleUnknown check fires first and the user
    ## gets a warning explaining why IDE features are unavailable.
    check classifyUnknownFile(ctx(
      canHandleUnknown = false,
      isRedirectAlias = true,
    )) == waShowWarning

  test "standaloneAlreadyRunning fires before canSpawn check → waGuardSkip not waSpawnAlongside":
    ## The user re-opens a file that already has a standalone nimsuggest running.
    ## A free slot happens to exist. If canSpawn were checked first, we'd spawn a
    ## redundant second nimsuggest for the same file. The standaloneAlreadyRunning
    ## guard fires first and correctly prevents the duplicate.
    check classifyUnknownFile(ctx(
      standaloneAlreadyRunning = true,
      canSpawn = true,
    )) == waGuardSkip

# ===========================================================================
# Suite 8: Historical regression cases
#
# Each test reproduces the exact WarnContext that caused a production bug.
# Names reference error_trace files from the error_traces/ directory.
# ===========================================================================

suite "classifyUnknownFile — historical regression cases":

  test "error_trace11: cross-project restart not blocked by redirect alias in intended slot":
    ## Before fix #18: the guard checked ns.finished and not ns.failed but not
    ## .file == key. A redirect alias satisfied those conditions → guard fired →
    ## the needed restart was skipped → the file had no IDE features forever.
    ## Fix: intendedAlreadyRunning is only true when .file == intendedProjectFile.
    ## Here the caller correctly sets intendedAlreadyRunning=false for a redirect alias,
    ## so we proceed with the restart.
    check classifyUnknownFile(ctx(
      intendedProjectFile = "api/api.nim",
      intendedAlreadyRunning = false,
    )) == waRestartForIntended

  test "error_trace25: second unimported file sees redirect alias → waCascadePrevention":
    ## fraction_layouts.nim opened first and triggered a kill-and-replace, creating
    ## a redirect alias at the user_interfaces.nim slot. proportion_tree_left.nim
    ## then fires warnIfUnknown and sees the alias. Before fix #18/#19, this
    ## returned waKillAndReplace, killing fraction_layouts's just-started nimsuggest.
    ## Neither file ever had stable IDE features. Now → waCascadePrevention.
    check classifyUnknownFile(ctx(
      path = "proportion_tree_left.nim",
      projectFile = "user_interfaces.nim",
      intendedProjectFile = "user_interfaces.nim",
      canHandleUnknown = true,
      canSpawn = false,
      isRedirectAlias = true,
      pathIsProjectEntryFile = false,
    )) == waCascadePrevention

  test "error_trace25: first unimported file has no redirect alias yet → waKillAndReplace":
    ## fraction_layouts.nim is the first to trigger a standalone restart in this
    ## session. The user_interfaces.nim slot has no alias yet. Correct behaviour
    ## is to kill user_interfaces.nim's nimsuggest and start one for fraction_layouts.
    check classifyUnknownFile(ctx(
      path = "fraction_layouts.nim",
      projectFile = "user_interfaces.nim",
      intendedProjectFile = "user_interfaces.nim",
      canHandleUnknown = true,
      canSpawn = false,
      isRedirectAlias = false,
    )) == waKillAndReplace

  test "fix #19: two unimported files open with a free slot → both get waSpawnAlongside":
    ## With maxNimsuggestProcesses=2, the first unimported file spawns alongside.
    ## The second file also sees canSpawn=true and spawns alongside the first.
    ## Both have their own nimsuggest. No kill-and-replace, no cascade.
    check classifyUnknownFile(ctx(
      path = "proportion_tree_left.nim",
      projectFile = "user_interfaces.nim",
      intendedProjectFile = "user_interfaces.nim",
      canHandleUnknown = true,
      canSpawn = true,
    )) == waSpawnAlongside

  test "happy path: file is already known by its assigned nimsuggest → waNoAction":
    ## Normal everyday use: the user opens a file that is part of their project.
    ## Nimsuggest compiled it at startup as a transitive import of the entry point.
    ## Hover, completions, and goto-definition all work from the first keystroke.
    check classifyUnknownFile(ctx(isKnown = true)) == waNoAction

  test "standalone already running with free slot → waGuardSkip not waSpawnAlongside":
    ## The user closes and re-opens fraction_layouts.nim. Its standalone nimsuggest
    ## is still running (not idle-timed-out yet). A second slot is free. Without
    ## the standaloneAlreadyRunning guard firing before the canSpawn check, we would
    ## spawn a duplicate nimsuggest for the same file and waste a slot.
    check classifyUnknownFile(ctx(
      canSpawn = true,
      standaloneAlreadyRunning = true,
    )) == waGuardSkip

# ===========================================================================
# Suite 9: pathIsProjectEntryFile — the cascade-prevention escape hatch
#
# pathIsProjectEntryFile = (path == projectFile). When true, the file being
# opened IS the project entry-file itself. Cascade prevention must not fire:
# the user is deliberately reclaiming the entry-file's nimsuggest slot.
# ===========================================================================

suite "classifyUnknownFile — pathIsProjectEntryFile escape hatch":

  test "redirect alias present, path is NOT the project entry-file → waCascadePrevention":
    ## proportion_tree_left.nim (path) is NOT user_interfaces.nim (projectFile).
    ## A redirect alias exists. Cascade prevention fires correctly: bailing prevents
    ## the just-started fraction_layouts standalone from being killed.
    check classifyUnknownFile(ctx(
      path = "proportion_tree_left.nim",
      projectFile = "user_interfaces.nim",
      canSpawn = false,
      isRedirectAlias = true,
      pathIsProjectEntryFile = false,
    )) == waCascadePrevention

  test "redirect alias present, path IS the project entry-file → waKillAndReplace":
    ## user_interfaces.nim (path == projectFile). The user clicked back on the
    ## project root file after a standalone restart had left a redirect alias.
    ## This is intentional: the user wants their project's nimsuggest back.
    ## pathIsProjectEntryFile=true is the escape hatch that lets kill-and-replace
    ## proceed. Without it, the user's entry-file would silently do nothing and
    ## remain without IDE features for the rest of the session.
    check classifyUnknownFile(ctx(
      path = "user_interfaces.nim",
      projectFile = "user_interfaces.nim",
      canSpawn = false,
      isRedirectAlias = true,
      pathIsProjectEntryFile = true,
    )) == waKillAndReplace
