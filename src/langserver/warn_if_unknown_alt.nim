## warn_if_unknown_alt.nim
##
## Refactored warnIfUnknown using the snapshot/classify/execute pattern (Option A).
##
## The three-proc structure:
##
##   gatherWarnContext   — async; the only place awaits happen
##   classifyUnknownFile — pure; the only place branching logic lives
##   executeWarnAction   — sync (modulo createOrRestartNimsuggest's internal waitFor);
##                         the only place state is mutated
##
## Why this decomposition:
##   All past bugs in warnIfUnknown (cascade loops, redirect-alias guard bypass,
##   wrong-branch selection) are pure decision-logic errors — they do not require a
##   running nimsuggest to reproduce or to test. classifyUnknownFile is the pure
##   distillation of that decision tree. It has zero async dependencies and can be
##   exercised with plain check() calls: construct a WarnContext literal, assert
##   the resulting WarnAction.
##
## Import note:
##   This file currently imports ls.nim for LanguageServer and related procs.
##   In the final integration, ls.nim will import this file instead; to avoid the
##   circular dependency the types and procs used here (shouldSpawnNimsuggest,
##   createOrRestartNimsuggest, showMessage) will need to move to a shared lower-level
##   module, or this file will be compiled as part of ls.nim via {.include.}.

import std/[strformat, tables, sets, options]
import chronos
import chronicles

import ../protocol/[types, enums]
import ../nimsuggest/suggestapi
import ./[utils, langserver_types]

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  WarnContext* = object
    ## Pure snapshot of all state relevant to the unknown-file decision.
    ##
    ## Captured synchronously after the two async calls (isKnown,
    ## shouldSpawnNimsuggest) complete. Any state that changes between
    ## snapshot and executeWarnAction is an inherent concurrency property
    ## of the design, not introduced here.
    path*: string
      ## Filesystem path derived from uri (uri.uriToPath)
    projectFile*: string
      ## Project currently assigned to uri in ls.openFiles
    intendedProjectFile*: string
      ## Project the regex mapping intended (may equal projectFile when reuse
      ## was not forced, or "" when no mapping matched)
    isKnown*: bool
      ## Did nimsuggest's 'known' command return true for this file?
    canHandleUnknown*: bool
      ## Does this nimsuggest instance advertise the nsUnknownFile capability?
    canSpawn*: bool
      ## Is a free nimsuggest slot available (below maxNimsuggestProcesses)?
    intendedAlreadyRunning*: bool
      ## A real (non-redirect-alias) nimsuggest is already live for
      ## intendedProjectFile. Guard: skip the cross-project restart.
    standaloneAlreadyRunning*: bool
      ## A real nimsuggest is already live with `path` as its own entry point.
      ## Guard: skip the standalone restart to avoid a restart loop.
    isRedirectAlias*: bool
      ## The projectFile slot in ls.projectFiles is a redirect alias
      ## (.file ≠ the key). Another standalone restart is already in progress
      ## for a different file in this project.
    pathIsProjectEntryFile*: bool
      ## True when path == projectFile: the file being opened IS the project
      ## entry-file itself. When true, cascade prevention must not fire even if
      ## the slot is a redirect alias — the user is deliberately reclaiming the
      ## entry-file's nimsuggest slot ("latest file wins" focus switch).

  WarnAction* = enum
    waNoAction
      ## File is known — nothing to do.
    waGuardSkip
      ## A guard fired to prevent a redundant or dangerous restart.
      ## Either intendedAlreadyRunning or standaloneAlreadyRunning was true.
    waCascadePrevention
      ## Redirect alias detected in the kill-and-replace path. Another
      ## standalone restart is already active for a different file in this
      ## project; bail to avoid thrashing.
    waRestartForIntended
      ## Cross-project restart: reuse was forced but this file belongs to
      ## a different (intended) project. Restart nimsuggest for that project.
    waShowWarning
      ## nimsuggest does not advertise unknownFile capability. Show the user
      ## a message explaining they need to import the file or configure projectMapping.
    waSpawnAlongside
      ## A free slot is available — spawn a second nimsuggest for this file
      ## as its own entry point without stopping the existing instance.
    waKillAndReplace
      ## At the process limit — evict the least recently used nimsuggest and
      ## spawn a new one with this file as the entry point.

# ---------------------------------------------------------------------------
# Pure decision function
# ---------------------------------------------------------------------------

proc classifyUnknownFile*(ctx: WarnContext): WarnAction =
  ## Pure mapping from observed state to intended action.
  ##
  ## No I/O. No async. No mutable state. Safe to call from any context.
  ##
  ## Every branch corresponds to a named failure mode seen in production.
  ## Regression tests construct the exact WarnContext that triggered each
  ## past bug and assert the correct WarnAction comes out.
  if ctx.isKnown:
    return waNoAction

  if ctx.intendedProjectFile != "" and ctx.intendedProjectFile != ctx.projectFile:
    # Cross-project branch.
    # Reuse was forced (process limit hit) but this file is not in the running
    # nimsuggest's module graph. The intended project is the one the regex mapping
    # selected before reuse kicked in.
    if ctx.intendedAlreadyRunning:
      # A live nimsuggest for the intended project already exists — no work needed.
      # This guard uses .file == intendedProjectFile to distinguish a real running
      # instance from a redirect alias that merely points at the right project
      # (error_trace25 / fix #18 cascade bug).
      return waGuardSkip
    return waRestartForIntended

  # Standalone branch: the file is unimported by its own project's nimsuggest.
  if not ctx.canHandleUnknown:
    # nimsuggest does not advertise nsUnknownFile; it cannot compile the file
    # in isolation at all. Only inform the user.
    return waShowWarning

  # canHandleUnknown=true but the v4 protocol does not compile standalone unknown
  # files (needsCompilation returns false when getModule returns nil — fix #18).
  # We must restart with this file as the entry point.
  if ctx.standaloneAlreadyRunning:
    # Already running as a standalone — avoid an infinite restart loop when
    # multiple unimported files are open in the same project.
    return waGuardSkip

  if ctx.canSpawn:
    # "Spawn alongside": a free slot is available.
    # Start a second nimsuggest for this file without stopping the existing one.
    # No redirect alias is created; the old nimsuggest keeps all its other files.
    return waSpawnAlongside

  # "Kill and replace": at the process limit.
  # Cascade prevention: redirect aliases only exist in this path (they are created
  # by the redirect assignment in executeWarnAction / waKillAndReplace). If the
  # projectFile slot is already a redirect alias, another standalone restart is
  # in progress for a different file in this project; bail to avoid cascade
  # (error_trace25, error_trace26 / fix #18 cascade bug, fix #19).
  if ctx.isRedirectAlias and not ctx.pathIsProjectEntryFile:
    return waCascadePrevention

  return waKillAndReplace

# ---------------------------------------------------------------------------
# Async gathering step
# ---------------------------------------------------------------------------

proc gatherWarnContext*(
    ls: LanguageServer,
    ns: Nimsuggest,
    uri: string,
    projectFile: string,
    intendedProjectFile: string,
): Future[WarnContext] {.async.} =
  ## Perform the two async calls and snapshot the relevant ls state.
  ##
  ## Everything after the two awaits is synchronous. The snapshot may be
  ## slightly stale by the time executeWarnAction runs if concurrent tasks
  ## mutate ls.projectFiles between the second await and the call — this is
  ## an inherent property of the current single-event-loop design and is not
  ## introduced by this refactor.
  let path = uri.uriToPath

  # ── Async calls ──────────────────────────────────────────────────────────
  let isKnown = await ns.isKnown(path)
  # shouldSpawnNimsuggest reads config and counts ls.projectFiles; only needed
  # for the standalone branch, but gathered unconditionally to keep all awaits
  # at the top and the snapshot read synchronously in one block below.
  let canSpawn = await ls.shouldSpawnNimsuggest()

  # ── Synchronous state snapshot ───────────────────────────────────────────

  # Is a real (non-redirect) nimsuggest live for intendedProjectFile?
  # A redirect alias has .file pointing at a different project; it does NOT
  # represent a live nimsuggest for the key. Checking .file == key is the
  # invariant established by fix #18.
  let intendedAlreadyRunning =
    if intendedProjectFile in ls.projectFiles:
      let p = ls.projectFiles[intendedProjectFile]
      p.file == intendedProjectFile and p.ns.finished and not p.ns.failed
    else:
      false

  # Is `path` already running as its own standalone entry point?
  let standaloneAlreadyRunning =
    if path in ls.projectFiles:
      let p = ls.projectFiles[path]
      p.file == path and p.ns.finished and not p.ns.failed
    else:
      false

  # Is the current projectFile slot a redirect alias?
  # After a kill-and-replace restart, ls.projectFiles[oldProject] is set to
  # ls.projectFiles[newStandaloneFile]. The alias has .file == newStandaloneFile,
  # which differs from the key (oldProject). Detecting this prevents cascade.
  let isRedirectAlias =
    if projectFile in ls.projectFiles:
      ls.projectFiles[projectFile].file != projectFile
    else:
      false

  return WarnContext(
    path: path,
    projectFile: projectFile,
    intendedProjectFile: intendedProjectFile,
    isKnown: isKnown,
    canHandleUnknown: ns.canHandleUnknown,
    canSpawn: canSpawn,
    intendedAlreadyRunning: intendedAlreadyRunning,
    standaloneAlreadyRunning: standaloneAlreadyRunning,
    isRedirectAlias: isRedirectAlias,
    pathIsProjectEntryFile: path == projectFile,
  )

# ---------------------------------------------------------------------------
# Side-effect execution
# ---------------------------------------------------------------------------

proc executeWarnAction*(
    ls: LanguageServer,
    uri: string,
    ctx: WarnContext,
    action: WarnAction,
) =
  ## Apply the side effects dictated by classifyUnknownFile.
  ##
  ## Mutates ls.projectFiles and ls.openFiles according to the action.
  ## No awaits in this proc (createOrRestartNimsuggest uses waitFor internally).
  ##
  ## Invariant: always clear errorCallback before project.stop() so that
  ## in-flight TCP commands don't trigger onErrorCallback when the process is
  ## killed, which would write spurious crashedFiles entries and fight the
  ## intended restart (fix #13 / fix #14).
  case action
  of waNoAction, waGuardSkip, waCascadePrevention:
    discard

  of waRestartForIntended:
    debug "warnIfUnknown: restarting nimsuggest for intended project",
      file = ctx.path, `from` = ctx.projectFile, to = ctx.intendedProjectFile
    if ctx.projectFile in ls.projectFiles:
      ls.projectFiles[ctx.projectFile].errorCallback = none(ProjectCallback)
      ls.projectFiles[ctx.projectFile].stop()
    ls.createOrRestartNimsuggest(ctx.intendedProjectFile, uri)
    # Redirect the old slot so files whose projectFile future already resolved
    # to projectFile can still reach a working nimsuggest.
    if ctx.intendedProjectFile in ls.projectFiles:
      ls.projectFiles[ctx.projectFile] = ls.projectFiles[ctx.intendedProjectFile]
    # Reassign all open files from the old project to the intended project so the
    # re-registration loop inside createOrRestartNimsuggest's addCallback includes them.
    for openUri, fileInfo in ls.openFiles.mpairs:
      if fileInfo.projectFile.finished and
          fileInfo.projectFile.read() == ctx.projectFile:
        let newFut = newFuture[string]("reassign-cross-project")
        newFut.complete(ctx.intendedProjectFile)
        fileInfo.projectFile = newFut

  of waShowWarning:
    ls.showMessage(
      fmt """{ctx.path} is not compiled as part of project {ctx.projectFile}.
In order to get the IDE features working you must either configure nim.projectMapping or import the module.""",
      MessageType.Warning,
    )

  of waSpawnAlongside:
    debug "warnIfUnknown: spawning standalone nimsuggest alongside existing",
      file = ctx.path, project = ctx.projectFile
    # Reassign this uri's projectFile future BEFORE calling createOrRestartNimsuggest.
    # The addCallback re-registration loop inside createOrRestartNimsuggest filters on
    # fileInfo.projectFile.read() == projectFile (the new standalone path). If the
    # reassignment happens after the call, the callback may fire before the future is
    # updated and miss adding uri to the new ns.openFiles (invariant from fix #19).
    if uri in ls.openFiles:
      let newFut = newFuture[string]("reassign-standalone")
      newFut.complete(ctx.path)
      ls.openFiles[uri].projectFile = newFut
    # Remove uri from the old nimsuggest's tracking set since it now has its own instance.
    if ctx.projectFile in ls.projectFiles and
        ls.projectFiles[ctx.projectFile].ns.finished and
        not ls.projectFiles[ctx.projectFile].ns.failed:
      ls.projectFiles[ctx.projectFile].ns.read().openFiles.excl(uri)
    # Does NOT stop the existing nimsuggest — "alongside" means both keep running.
    ls.createOrRestartNimsuggest(ctx.path, uri)

  of waKillAndReplace:
    debug "warnIfUnknown: replacing nimsuggest (at limit) with standalone",
      file = ctx.path, project = ctx.projectFile
    if ctx.projectFile in ls.projectFiles:
      ls.projectFiles[ctx.projectFile].errorCallback = none(ProjectCallback)
      ls.projectFiles[ctx.projectFile].stop()
    ls.createOrRestartNimsuggest(ctx.path, uri)
    # Create the redirect alias so files already assigned to projectFile still
    # find a working nimsuggest (their futures resolved before the restart).
    # The alias has .file == ctx.path ≠ ctx.projectFile; isRedirectAlias detects this.
    if ctx.path in ls.projectFiles:
      ls.projectFiles[ctx.projectFile] = ls.projectFiles[ctx.path]
    # Reassign all open files from the old project to the new standalone path.
    for openUri, fileInfo in ls.openFiles.mpairs:
      if fileInfo.projectFile.finished and
          fileInfo.projectFile.read() == ctx.projectFile:
        let newFut = newFuture[string]("reassign-kill-replace")
        newFut.complete(ctx.path)
        fileInfo.projectFile = newFut

# ---------------------------------------------------------------------------
# Orchestrator — wires the three steps together
# ---------------------------------------------------------------------------

proc warnIfUnknownAlt*(
    ls: LanguageServer,
    ns: Nimsuggest,
    uri: string,
    projectFile: string,
    intendedProjectFile: string = "",
): Future[void] {.async.} =
  ## Drop-in replacement for warnIfUnknown.
  ##
  ## Gather → Classify → Execute. The three steps are independent:
  ##   - Gather is tested with async integration tests (fake nimsuggest).
  ##   - Classify is tested with pure unit tests (WarnContext literals).
  ##   - Execute is tested with integration tests verifying state mutations.
  let ctx = await ls.gatherWarnContext(ns, uri, projectFile, intendedProjectFile)
  let action = classifyUnknownFile(ctx)
  debug "warnIfUnknown action selected",
    file = ctx.path,
    project = ctx.projectFile,
    intended = ctx.intendedProjectFile,
    isKnown = ctx.isKnown,
    canHandleUnknown = ctx.canHandleUnknown,
    canSpawn = ctx.canSpawn,
    intendedAlreadyRunning = ctx.intendedAlreadyRunning,
    standaloneAlreadyRunning = ctx.standaloneAlreadyRunning,
    isRedirectAlias = ctx.isRedirectAlias,
    action = $action
  ls.executeWarnAction(uri, ctx, action)
