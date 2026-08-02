import std/[os, options, sequtils, times]
import chronos
import chronicles

import ../protocol/types
import ../nimsuggest/nimsuggest
import ../nimble/nimble
import ../nimcheck/nimcheck
import ./[configurations, langserver_types, constants, utils]

proc leastRecentlyUsedProjectFile*(ls: LanguageServer): string =
  ## Returns the projectFiles key whose nimsuggest has been least recently used.
  ## Only considers real entries (proj.file == key) — redirect aliases are skipped
  ## because they share a Project with the canonical key and picking the alias key
  ## causes cascade prevention to misfire. Falls back to the first key if no real
  ## finished instance exists (e.g. all still compiling).
  var oldest = now()
  result = ls.projectFiles.keys.toSeq[0]
  for k, proj in ls.projectFiles.pairs:
    if proj.file != k:
      continue  # skip redirect aliases
    if not proj.ns.finished or proj.ns.failed:
      continue
    let date = proj.lastCmdDate.get(dateTime(1970, mJan, 1, 0, 0, 0, 0, utc()))
    if date < oldest:
      oldest = date
      result = k

proc warnIfUnknown*(
    ls: LanguageServer,
    ns: Nimsuggest,
    uri: string,
    projectFile: string,
    intendedProjectFile: string = "",
): Future[void] {.async.} =
  let path = uri.uriToPath
  let isFileKnown = await ns.isKnown(path)
  if not isFileKnown:
    if intendedProjectFile != "" and intendedProjectFile != projectFile:
      # Reuse was forced (maxNimsuggestProcesses limit hit) but the file is not
      # in the running nimsuggest's module graph. Restart for the intended
      # (consumer-level) project so the user gets full IDE features.
      # Guard: if a nimsuggest for the intended project is already starting or
      # running, skip to avoid a redundant restart.
      if intendedProjectFile in ls.projectFiles:
        let existingProj = ls.projectFiles[intendedProjectFile]
        if existingProj.file == intendedProjectFile and
            existingProj.ns.finished and not existingProj.ns.failed:
          debug "warnIfUnknown: intended project already has nimsuggest, skipping restart",
            file = path, intended = intendedProjectFile
          return

      debug "warnIfUnknown: restarting nimsuggest for intended project after unknownFile detection",
        file = path, `from` = projectFile, to = intendedProjectFile
      if projectFile in ls.projectFiles:
        # Clear the error callback before stopping so onErrorCallback does not
        # treat this intentional stop as a crash (which would block the file and
        # auto-restart the old nimsuggest, fighting against the intended restart).
        ls.projectFiles[projectFile].errorCallback = none(ProjectCallback)
        ls.projectFiles[projectFile].stop()
      ls.createOrRestartNimsuggest(intendedProjectFile, uri)
      # Redirect the old slot so files already assigned to it still find a
      # working nimsuggest (their projectFile future already resolved to projectFile).
      if intendedProjectFile in ls.projectFiles:
        ls.projectFiles[projectFile] = ls.projectFiles[intendedProjectFile]
      # Reassign all open files from the old project to the new project so the
      # re-registration loop (which filters on projectFile) includes them.
      for openUri, fileInfo in ls.openFiles.mpairs:
        if fileInfo.projectFile.finished and
            fileInfo.projectFile.read() == projectFile:
          let newFut = newFuture[string]("reassign")
          newFut.complete(intendedProjectFile)
          fileInfo.projectFile = newFut
          
    elif not ns.canHandleUnknown:
      ls.showMessage(
        fmt """{path} is not compiled as part of project {projectFile}.
  In order to get the IDE features working you must either configure nim.projectMapping or import the module.""",
        MessageType.Warning,
      )
    else:
      # canHandleUnknown=true but the v4 nimsuggest protocol does not compile
      # unknown files standalone: needsCompilation(fileIndex) returns false for
      # files with no module in the graph. Restart nimsuggest with the open file
      # as its own entry point to give the user full IDE features in isolation.
      #
      # Guard: if nimsuggest is already running for this file as its own project,
      # skip to avoid a restart loop when multiple unimported files are open.
      if path in ls.projectFiles:
        let existingProj = ls.projectFiles[path]
        if existingProj.file == path and
            existingProj.ns.finished and not existingProj.ns.failed:
          debug "warnIfUnknown: nimsuggest already running for file as standalone, skipping",
            file = path
          return
      let canSpawn = await ls.shouldSpawnNimsuggest()
      if canSpawn:
        # "Spawn alongside" path: a free slot is available — start a second
        # nimsuggest for this file without stopping the existing one.
        debug "warnIfUnknown: spawning standalone nimsuggest alongside existing",
          file = path, project = projectFile
        # Reassign this file's projectFile future BEFORE spawning so the
        # addCallback re-registration loop (which checks projectFile.read() == path)
        # picks up this uri and adds it to the new ns.openFiles.
        if uri in ls.openFiles:
          let newFut = newFuture[string]("reassign-standalone")
          newFut.complete(path)
          ls.openFiles[uri].projectFile = newFut
        # Remove from old nimsuggest's tracking since it now has its own.
        if projectFile in ls.projectFiles and
            ls.projectFiles[projectFile].ns.finished and
            not ls.projectFiles[projectFile].ns.failed:
          ls.projectFiles[projectFile].ns.read().openFiles.excl(uri)
        ls.createOrRestartNimsuggest(path, uri)
      else:
        # "Kill and replace" path: at the process limit — replace the least recently
        # used nimsuggest with a new one for this file.
        #
        # Cascade prevention: redirect aliases exist only in this path (created by
        # the redirect alias assignment below). If the project slot is already a
        # redirect alias, another standalone restart is in progress for a different
        # file in this project; bail unless this file is the project entry-file itself.
        if projectFile in ls.projectFiles:
          let projEntry = ls.projectFiles[projectFile]
          if projEntry.file != projectFile and path != projectFile:
            debug "warnIfUnknown: cascade prevention — standalone restart already active for another file in this project",
              file = path, project = projectFile, activeFile = projEntry.file
            return
        debug "warnIfUnknown: replacing nimsuggest (at limit) with standalone for file",
          file = path, project = projectFile
        if projectFile in ls.projectFiles:
          ls.projectFiles[projectFile].errorCallback = none(ProjectCallback)
          ls.projectFiles[projectFile].stop()
        ls.createOrRestartNimsuggest(path, uri)
        if path in ls.projectFiles:
          ls.projectFiles[projectFile] = ls.projectFiles[path]
        for openUri, fileInfo in ls.openFiles.mpairs:
          if fileInfo.projectFile.finished and
              fileInfo.projectFile.read() == projectFile:
            let newFut = newFuture[string]("reassign")
            newFut.complete(path)
            fileInfo.projectFile = newFut

proc checkFile*(ls: LanguageServer, uri: string): Future[void] {.raises: [], gcsafe.}

proc didCloseFile*(ls: LanguageServer, uri: string): Future[void] {.async.} =
  debug "Closed the following document:", uri = uri

  if uri notin ls.openFiles:
    return

  if ls.openFiles[uri].changed:
    # check the file if it is closed but not saved.
    traceAsyncErrors ls.checkFile(uri)

  ls.openFiles.del uri

  # Sync ns.openFiles: there is no nimsuggest "close" command, so we maintain
  # the per-instance tracking set manually. Without this, stale entries remain
  # in ns.openFiles after the file is closed, causing cancelPendingFileChecks
  # to attempt ls.openFiles[uri] on a key that no longer exists.
  for project in ls.projectFiles.values:
    if project.ns.finished and not project.ns.failed:
      let nsRef = project.ns.read()
      if uri in nsRef.openFiles:
        nsRef.openFiles.excl(uri)

proc makeIdleFile*(ls: LanguageServer, file: NlsFileInfo): Future[void] {.async.} =
  let uri = file.textDocument.uri
  if uri in ls.openFiles:
    await ls.didCloseFile(uri)
    ls.idleOpenFiles[uri] = file
    ls.openFiles.del(uri)

proc getProjectFile*(fileUri: string, ls: LanguageServer): Future[string] {.async.}
proc getIntendedProjectFile*(fileUri: string, ls: LanguageServer): Future[string] {.async.}

proc didRenameFile*(
    ls: LanguageServer, oldUri, newUri: string
): Future[void] {.async.} =
  debug "File renamed", oldUri = oldUri, newUri = newUri

  # Move the stash file so any pending content checks use the right path
  let oldStash = ls.uriStorageLocation(oldUri)
  let newStash = ls.uriStorageLocation(newUri)
  if oldStash.fileExists:
    try:
      moveFile(oldStash, newStash)
    except Exception as e:
      debug "Failed to move stash file on rename", oldStash = oldStash, newStash = newStash, msg = e.msg

  # If a .nimble file was renamed, invalidate its dump cache entry
  let oldPath = uriToPath(oldUri)
  if oldPath.endsWith(".nimble"):
    ls.nimDumpCache.del(oldPath)
    ls.nimDumpCache.del(uriToPath(newUri))

  # If the file is currently open, migrate its entry to the new URI
  if oldUri in ls.openFiles:
    let oldInfo = ls.openFiles[oldUri]
    let oldProjectFile = await oldInfo.projectFile
    let newProjectFile = await getProjectFile(uriToPath(newUri), ls)

    let newFut = newFuture[string]("rename")
    newFut.complete(newProjectFile)
    ls.openFiles[newUri] = NlsFileInfo(
      projectFile: newFut,
      changed: oldInfo.changed,
      fingerTable: oldInfo.fingerTable,
      textDocument: TextDocumentItem(
        uri: newUri,
        languageId: oldInfo.textDocument.languageId,
        version: oldInfo.textDocument.version,
        text: oldInfo.textDocument.text,
      ),
    )
    ls.openFiles.del(oldUri)

    # If this was a .nim rename, nimsuggest's module graph is stale (it still
    # references the old filename). Trigger an in-process full recompile so the
    # graph is rebuilt before the next sug/chk request arrives. This avoids a
    # SIGSEGV in nimsuggest where getModule returns nil after recompilePartially
    # fails on the now-missing old file.
    if oldPath.endsWith(".nim") and oldProjectFile in ls.projectFiles:
      let ns = await ls.projectFiles[oldProjectFile].ns
      if ns != nil:
        traceAsyncErrors ns.recompile()

    # If the file moved to a different project, ensure nimsuggest is running for it
    if newProjectFile != oldProjectFile and newProjectFile notin ls.projectFiles:
      let shouldSpawn = await ls.shouldSpawnNimsuggest()
      if shouldSpawn:
        ls.createOrRestartNimsuggest(newProjectFile, newUri)

proc didDeleteFile*(ls: LanguageServer, uri: string): Future[void] {.async.} =
  debug "File deleted", uri = uri
  let path = uriToPath(uri)

  # If a .nimble file was deleted, invalidate its dump cache entry
  if path.endsWith(".nimble"):
    ls.nimDumpCache.del(path)

  # Sync ns.openFiles: the file is gone from disk, so remove it from every
  # nimsuggest instance's tracking set
  for project in ls.projectFiles.values:
    if project.ns.finished and not project.ns.failed:
      let nsRef = project.ns.read()
      if uri in nsRef.openFiles:
        nsRef.openFiles.excl(uri)

  # Trigger a full recompile on all live nimsuggest instances. This converts
  # the mid-command IOError (recompilePartially hitting the missing file) into
  # a controlled degraded state via recompileFullProject, which handles
  # "cannot open file" gracefully. We recompile all instances conservatively
  # since we cannot know which projects import the deleted file.
  if path.endsWith(".nim"):
    for project in ls.projectFiles.values:
      if project.ns.finished and not project.ns.failed:
        traceAsyncErrors project.ns.read().recompile()

proc didOpenFile*(
    ls: LanguageServer, textDocument: TextDocumentItem
): Future[void] {.async.} =
  with textDocument:
    if uri in ls.openFiles:
      # Already tracked — this didOpen arrived after a didRenameFiles that
      # already migrated the entry to this URI. Nothing to do.
      debug "didOpenFile: URI already tracked (post-rename), skipping", uri = uri
      return

    # Wait for config before getProjectFile so projectMapping and
    # maxNimsuggestProcesses are available when the project file is resolved.
    discard await ls.waitForWorkspaceConfiguration()

    # Re-check after the await: a concurrent didOpen or didRenameFile may have
    # inserted this URI while we were waiting for configuration.
    if uri in ls.openFiles:
      debug "didOpenFile: URI tracked after config wait (concurrent open), skipping",
        uri = uri
      return

    debug "New document opened for URI:", uri = uri
    let
      file = open(ls.uriStorageLocation(uri), fmWrite)
      projectFileFuture = getProjectFile(uriToPath(uri), ls)

    ls.openFiles[uri] = NlsFileInfo(
      projectFile: projectFileFuture,
      changed: false,
      fingerTable: @[],
      textDocument: textDocument,
    )

    if uri in ls.idleOpenFiles:
      ls.idleOpenFiles.del(uri)

    let projectFile = await projectFileFuture
    debug "Document associated with the following projectFile",
      uri = uri, projectFile = projectFile

    # Resolve the mapping-intended project before the reuse override. This is
    # passed to warnIfUnknown so it can restart nimsuggest for the right project
    # when the assigned (reused) nimsuggest doesn't know the file.
    let intendedProjectFile = await getIntendedProjectFile(uriToPath(uri), ls)

    if not ls.projectFiles.hasKey(projectFile):
      let shouldSpawn = await ls.shouldSpawnNimsuggest()
      if shouldSpawn:
        debug "Will create nimsuggest for this file", uri = uri
        ls.createOrRestartNimsuggest(projectFile, uri)

    for line in text.splitLines:
      if uri in ls.openFiles:
        ls.openFiles[uri].fingerTable.add line.createUTFMapping()
        file.writeLine line
    file.close()
    let ns = await ls.tryGetNimSuggest(uri)
    if ns.isSome:
      discard ls.warnIfUnknown(ns.get(), uri, projectFile, intendedProjectFile)
      ns.get().openFiles.incl(uri)

    let projectFileUri = projectFile.pathToUri
    if projectFileUri notin ls.openFiles:
      var textDocument = TextDocumentItem(
        uri: projectFileUri, languageId: "nim", version: 0, text: readFile(projectFile)
      )

      await didOpenFile(ls, textDocument)

      debug "Opening project file", uri = projectFile, file = uri
    ls.showMessage(fmt "Opening {uri}", MessageType.Info)


proc extractCrashedFile*(cmd: string): string =
  ## Extract the first quoted file path from a nimsuggest command string.
  ## e.g. `sug "/path/file.nim";"/stash.nim":4:12` → "/path/file.nim"
  let start = cmd.find('"')
  if start < 0: return ""
  let stop = cmd.find('"', start + 1)
  if stop < 0: return ""
  cmd[start + 1 ..< stop]

proc onErrorCallback(args: (LanguageServer, string), project: Project) =
  let
    ls = args[0]
    uri = args[1]
  debug "NimSuggest needed to be restarted due to an error "
  ls.failTable[project.file] = ls.failTable.getOrDefault(project.file, 0) + 1
  debug "Fail count", count = ls.failTable[project.file]
  let crashedFile = project.lastCmd.extractCrashedFile()
  if crashedFile != "" and crashedFile != project.file:
    ls.crashedFiles.mgetOrPut(project.file, initHashSet[string]()).incl crashedFile
    warn "Blocking file from nimsuggest after crash; save the file to re-enable",
      file = crashedFile, project = project.file
  let configuration = ls.getWorkspaceConfiguration().waitFor()
  warn "Server stopped.", projectFile = project.file
  try:
    if configuration.autoRestart.get(true) and project.ns.completed and
        project.ns.read.successfullCall:
      ls.createOrRestartNimsuggest(project.file, uri)
    else:
      ls.showMessage(
        fmt "Server failed with {project.errorMessage}.", MessageType.Error
      )
  except CatchableError as ex:
    error "An error has ocurred while handling nimsuggest err", msg = ex.msg
    writeStacktrace(ex)
  finally:
    if project.file != "":
      ls.projectErrors.add ProjectError(
        projectFile: project.file,
        errorMessage: project.errorMessage,
        lastKnownCmd: project.lastCmd,
      )
      ls.sendStatusChanged()


proc getProjectFile*(fileUri: string, ls: LanguageServer): Future[string] {.async.} =
  let
    rootPath =
      case ls.serverMode
      of mcp:
        ls.mcpInitializeParams.getRootPath()
      of lsp:
        ls.lspInitializeParams.getRootPath()
    pathRelativeToRoot = fileUri.tryRelativeTo(rootPath)
    mappings = ls.getWorkspaceConfiguration.await().projectMapping.get(@[])

  for mapping in mappings:
    var m: RegexMatch2
    if pathRelativeToRoot.isSome and
        find(pathRelativeToRoot.get(), re2(mapping.fileRegex), m):
      ls.showMessage(
        fmt"RegEx matched `{mapping.fileRegex}` for file `{fileUri}`", MessageType.Info
      )
      result = rootPath / mapping.projectFile
      if fileExists(result):
        trace "getProjectFile?",
          project = result, uri = fileUri, matchedRegex = mapping.fileRegex
        let shouldSpawn = await ls.shouldSpawnNimsuggest()
        if not shouldSpawn:
          result = ls.leastRecentlyUsedProjectFile()
          debug "Reached the maximum instances of nimsuggest (mapping), reusing least recently used instance",
            project = result
        return result
    else:
      trace "getProjectFile does not match",
        uri = fileUri, matchedRegex = mapping.fileRegex

  #If we reached the maximum instances of nimsuggest, we just return the first project
  let shouldSpawn = await ls.shouldSpawnNimsuggest()
  if not shouldSpawn:
    result = ls.leastRecentlyUsedProjectFile()
    debug "Reached the maximum instances of nimsuggest, reusing least recently used instance",
      project = result
    return result

  result = await ls.getProjectFileAutoGuess(fileUri)
  if result in ls.projectFiles:
    let ns = await ls.projectFiles[result].ns
    let isKnown = await ns.isKnown(fileUri)
    if ns.canHandleUnknown and not isKnown:
      debug "File is not known by nimsuggest", uri = fileUri, projectFile = result
      result = fileUri

  if result == "":
    result = fileUri

  debug "getProjectFile ", project = result, fileUri = fileUri

proc getIntendedProjectFile*(fileUri: string, ls: LanguageServer): Future[string] {.async.} =
  ## Returns the project file that projectMapping intends for fileUri,
  ## WITHOUT the reuse fallback applied by getProjectFile. Returns "" if no
  ## mapping matches (auto-guess projects are not considered "intended").
  let
    rootPath =
      case ls.serverMode
      of mcp:
        ls.mcpInitializeParams.getRootPath()
      of lsp:
        ls.lspInitializeParams.getRootPath()
    pathRelativeToRoot = fileUri.tryRelativeTo(rootPath)
    mappings = ls.getWorkspaceConfiguration.await().projectMapping.get(@[])
  for mapping in mappings:
    var m: RegexMatch2
    if pathRelativeToRoot.isSome and
        find(pathRelativeToRoot.get(), re2(mapping.fileRegex), m):
      let intended = rootPath / mapping.projectFile
      if fileExists(intended):
        return intended
  return ""

proc checkFile*(ls: LanguageServer, uri: string): Future[void] {.async.} =
  let conf = await ls.getAndWaitForWorkspaceConfiguration()
  let useNimCheck = conf.useNimCheck.get(USE_NIM_CHECK_BY_DEFAULT)
  let nimPath = conf.getNimPath()
  let token = fmt "Checking file {uri}"
  ls.workDoneProgressCreate(token)
  ls.progress(token, "begin", fmt "Checking {uri.uriToPath}")

  let path = uriToPath(uri)

  if useNimCheck and nimPath.isSome:
    let checkResults = await nimCheck(uriToPath(uri), nimPath.get)
    ls.progress(token, "end")
    ls.sendDiagnostics(checkResults, path)
    return

  let ns = await ls.tryGetNimsuggest(uri)
  if ns.isSome:
    discard await ns.get().changed(path, ls.uriToStash(uri))
    let diagnostics = ns.get().chkFile(path, ls.uriToStash(uri)).await()
    ls.progress(token, "end")
    ls.sendDiagnostics(diagnostics, path)
  else:
    ls.progress(token, "end")

