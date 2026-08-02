import std/[os, sequtils, options, strformat, strutils, times]

import chronos
import chronicles

import ./suggestapi
import ../protocol/types
import ../langserver/[langserver_types, configurations, utils, constants, files]
import ../nimble/nimble
import ../nim_compiler/nim_compiler


proc getWorkingDir(ls: LanguageServer, path: string): Future[string] {.async.} =
  let rootPath =
    case ls.serverMode
    of lsp: ls.lspInitializeParams.getRootPath
    of mcp: ls.mcpInitializeParams.getRootPath

  let
    pathRelativeToRoot = path.tryRelativeTo(rootPath)
    mapping = ls.getWorkspaceConfiguration.await().workingDirectoryMapping.get(@[])

  result = getCurrentDir()

  for m in mapping:
    if pathRelativeToRoot.isSome and m.projectFile == pathRelativeToRoot.get():
      result = rootPath / m.directory
      break

proc getNimSuggestPathAndVersion(
    ls: LanguageServer, conf: NlsConfig, workingDir: string
): Future[(string, string)] {.async.} =
  #Attempting to see if the project is using a custom Nim version, if it's the case this will be slower than usual
  let nimbleDumpInfo = await ls.getNimbleDumpInfo("")
  let nimDir = nimbleDumpInfo.nimDir.get ""

  var nimsuggestPath = expandTilde(conf.nimsuggestPath.get(""))
  var nimVersion = ""
  if nimsuggestPath == "":
    if nimDir != "" and nimDir.dirExists:
      nimVersion = getNimVersion(nimDir) & " from " & nimDir
      nimsuggestPath = nimDir / "nimsuggest"
    else:
      nimVersion = getNimVersion("")
      nimsuggestPath = findExe "nimsuggest"
  else:
    nimVersion = getNimVersion(nimsuggestPath.parentDir)
  # ls.showMessage(fmt "Using {nimVersion}", MessageType.Info)
  debug "Using {nimVersion}", nimVersion = nimVersion
  (nimsuggestPath, nimVersion)

proc createOrRestartNimsuggest*(
  ls: LanguageServer, projectFile: string, uri = ""
) {.gcsafe, raises: [].}

proc shouldSpawnNimsuggest*(ls: LanguageServer): Future[bool] {.async.} =
  # Count ALL projectFiles entries (including projects still starting), not just
  # finished ones — otherwise concurrent didOpen tasks all see count=0 and all spawn.
  let nsCount = ls.projectFiles.len
  let conf = await ls.getWorkspaceConfiguration
  let maxNimsuggestProcesses = conf.maxNimsuggestProcesses.get(NIM_MAX_NS_PROCESSES)
  result = maxNimsuggestProcesses == 0 or nsCount < maxNimsuggestProcesses
  debug "shouldSpawnNimsuggest",
    result = result, nsCount = nsCount, maxNimsuggestProcesses = maxNimsuggestProcesses

proc initNimsuggestInstances*(ls: LanguageServer, rootPath: string) {.async.} =
  if rootPath == "":
    return

  let nimbleFiles = walkFiles(rootPath / "*.nimble").toSeq
  if nimbleFiles.len > 0:
    let nimbleFile = nimbleFiles[0]
    debug "Starting nimble dump for  ", nimbleFile
    let nimbleDumpInfo = await ls.getNimbleDumpInfo(nimbleFile)
    ls.entryPoints = nimbleDumpInfo.getNimbleEntryPoints(rootPath)
    
    debug "Finished nimble dump for  ", nimbleFile
    for entryPoint in ls.entryPoints:
      debug "Starting nimsuggest for entry point ", entry = entryPoint
      if entryPoint notin ls.projectFiles:
        let shouldSpawn = await ls.shouldSpawnNimsuggest()
        if shouldSpawn:
          ls.createOrRestartNimsuggest(entryPoint)
        else:
          debug "Limit reached, skipping entry point", entryPoint = entryPoint
          break

proc getNimsuggestInner(ls: LanguageServer, uri: string): Future[Nimsuggest] {.async.} =
  assert uri in ls.openFiles, "File not open"

  let projectFile = await ls.openFiles[uri].projectFile
  if not ls.projectFiles.hasKey(projectFile):
    let shouldSpawn = await ls.shouldSpawnNimsuggest()
    if shouldSpawn:
      debug "Creating new nimsuggest instance", uri = uri, projectFile = projectFile
      ls.createOrRestartNimsuggest(projectFile, uri)
      # Wait a bit to allow nimsuggest to start
      await sleepAsync(10)
    else:
      debug "Limit reached, reusing existing nimsuggest", uri = uri

  const MaxFails = 10
  if projectFile in ls.failTable and ls.failTable[projectFile] >= MaxFails:
    if ls.projectFiles.len > 1:
      let nextNs = ls.leastRecentlyUsedProjectFile()
      if nextNs != projectFile:
        debug "Reusing least recently used nimsuggest after repeated failures",
          uri = uri, projectFile = nextNs
        return await ls.projectFiles[nextNs].ns
    return nil

  # Check multiple times with small delays.
  # Skip entries whose ns is still pending (sentinel from createOrRestartNimsuggest).
  var attempts = 0
  const maxAttempts = 10
  while attempts < maxAttempts:
    if projectFile in ls.projectFiles and
        ls.projectFiles[projectFile].ns.finished:
      ls.lastNimsuggest = ls.projectFiles[projectFile].ns
      return await ls.projectFiles[projectFile].ns

    inc attempts
    if attempts < maxAttempts:
      await sleepAsync(100)
      debug "Waiting for nimsuggest to initialize",
        uri = uri, projectFile = projectFile, attempt = attempts

  debug "Failed to get nimsuggest after waiting", uri = uri, projectFile = projectFile
  return nil

proc tryGetNimsuggest*(
  ls: LanguageServer, uri: string
): Future[Option[Nimsuggest]] {.raises: [], gcsafe.}



proc tryGetNimsuggest*(
    ls: LanguageServer, uri: string
): Future[Option[Nimsuggest]] {.async.} =
  if uri in ls.idleOpenFiles:
    let idleFile = ls.idleOpenFiles[uri]
    await didOpenFile(ls, idleFile.textDocument)

  if uri notin ls.openFiles:
    return none(NimSuggest)

  let path = uri.uriToPath
  let fileInfo = ls.openFiles[uri]
  if fileInfo.projectFile.finished and not fileInfo.projectFile.failed:
    let pf = fileInfo.projectFile.read()
    if pf in ls.crashedFiles and path in ls.crashedFiles[pf]:
      return none(Nimsuggest)

  var retryCount = 0
  const maxRetries = 3
  while retryCount < maxRetries:
    let ns = await getNimsuggestInner(ls, uri)
    if not ns.isNil:
      return some ns

    # If nimsuggest is nil, wait a bit and retry
    inc retryCount
    if retryCount < maxRetries:
      debug "Nimsuggest not ready, retrying...", uri = uri, attempt = retryCount
      await sleepAsync(10000 * retryCount) # Exponential backoff

  debug "Nimsuggest not found after retries", uri = uri
  return none(NimSuggest)

proc createOrRestartNimsuggest*(
    ls: LanguageServer, projectFile: string, uri = ""
) {.gcsafe, raises: [].} =
  try:
    debug "Starting createOrRestartNimsuggest", projectFile = projectFile, uri = uri
    # Reserve the slot immediately so concurrent shouldSpawnNimsuggest checks see it.
    # The sentinel has a pending ns future; getNimsuggestInner skips pending entries
    # and retries until the real project replaces this sentinel.
    if projectFile notin ls.projectFiles:
      ls.projectFiles[projectFile] =
        Project(file: projectFile, ns: newFuture[Nimsuggest]("pending"))
    let
      configuration = ls.getWorkspaceConfiguration().waitFor()
      workingDir = ls.getWorkingDir(projectFile).waitFor()
      (nimsuggestPath, version) =
        ls.getNimSuggestPathAndVersion(configuration, workingDir).waitFor()
      timeout = configuration.timeout.get(REQUEST_TIMEOUT)
      restartCallback = proc(ns: Nimsuggest) {.gcsafe, raises: [].} =
        warn "Restarting the server due to requests being to slow",
          projectFile = projectFile
        ls.showMessage(
          fmt "Restarting nimsuggest for file {projectFile} due to timeout.",
          MessageType.Warning,
        )
        ls.createOrRestartNimsuggest(projectFile, uri)
        ls.sendStatusChanged()
      errorCallback = partial(onErrorCallback, (ls, uri))

    let nimPaths = findNimblePaths(projectFile)
    debug "Creating new nimsuggest project",
      projectFile = projectFile, nimPathCount = nimPaths.len

    let projectNext = waitFor createNimsuggest(
      projectFile,
      nimsuggestPath,
      version,
      timeout,
      restartCallback,
      errorCallback,
      workingDir,
      configuration.logNimsuggest.get(false),
      configuration.exceptionHintsEnabled,
      nimPaths,
    )

    if projectFile in ls.projectFiles:
      var project = ls.projectFiles[projectFile]
      project.stop()
    ls.projectFiles[projectFile] = projectNext

    projectNext.ns.addCallback do(fut: Future[Nimsuggest]):
      if fut.failed:
        let msg = fut.error.msg
        error "Nimsuggest initialization failed", projectFile = projectFile, error = msg

        ls.showMessage(
          fmt "Nimsuggest initialization for {projectFile} failed with: {msg}",
          MessageType.Error,
        )
      else:
        debug "Nimsuggest initialized successfully", projectFile = projectFile
        ls.failTable.del(projectFile)

        ls.showMessage(fmt "Nimsuggest initialized for {projectFile}", MessageType.Info)
        traceAsyncErrors ls.checkProject(uri)
        let newNs = fut.read()
        for openUri in ls.openFiles.keys:
          let fileInfo = ls.openFiles[openUri]
          if fileInfo.projectFile.finished and
              fileInfo.projectFile.read() == projectFile:
            let openPath = openUri.uriToPath
            if projectFile in ls.crashedFiles and
                openPath in ls.crashedFiles[projectFile]:
              # Skip crash-inducing files: don't re-register them in the new
              # instance's tracking set or issue checkFile, which would bypass
              # the tryGetNimsuggest guard and re-trigger the crash.
              continue
            newNs.openFiles.incl openUri
      ls.sendStatusChanged()
  except CatchableError as ex:
    error "Failed to create/restart nimsuggest",
      projectFile = projectFile, error = ex.msg

proc restartAllNimsuggestInstances(ls: LanguageServer) =
  debug "Restarting all nimsuggest instances"
  for projectFile in ls.projectFiles.keys.toSeq:
    ls.createOrRestartNimsuggest(projectFile, projectFile.pathToUri)

proc stopNimsuggestProcesses*(ls: LanguageServer) {.async.} =
  if not ls.childNimsuggestProcessesStopped:
    debug "stopping child nimsuggest processes"
    ls.childNimsuggestProcessesStopped = true
    for project in ls.projectFiles.values:
      project.stop()
  else:
    debug "child nimsuggest processes already stopped: CHECK!"

proc stopNimsuggestProcessesP*(ls: LanguageServer) =
  waitFor stopNimsuggestProcesses(ls)


proc removeIdleNimsuggests*(ls: LanguageServer) {.async.} =
  const DefaultNimsuggestIdleTimeout = 120000
  let timeout = ls.getWorkspaceConfiguration().await().nimsuggestIdleTimeout.get(
      DefaultNimsuggestIdleTimeout
    )
  var toStop = newSeq[Project]()
  var seenFiles: HashSet[string]
  for project in ls.projectFiles.values:
    if project.file in ls.entryPoints: #we only remove non entry point nimsuggests
      continue
    # Deduplicate: redirect aliases share the same project.file; only process once.
    if project.file in seenFiles:
      continue
    seenFiles.incl(project.file)
    if project.lastCmdDate.isSome:
      let passedTime = now() - project.lastCmdDate.get()
      if passedTime.inMilliseconds > timeout:
        toStop.add(project)

  for project in toStop:
    debug "Removing idle nimsuggest", project = project.file
    project.errorCallback = none(ProjectCallback)

    let ns = await project.ns
    for uri in ns.openFiles.toSeq:
      debug "Removing idle nimsuggest open file", uri = uri
      ls.openFiles.withValue(uri, info):
        await ls.makeIdleFile(info[])
    project.stop()
    # Delete ALL keys pointing to this project: both the main key and any redirect
    # aliases created by warnIfUnknown (where the key ≠ project.file). Using only
    # del(project.file) would leave alias keys forever since their project.file also
    # equals the stopped project's file, so del(project.file) is a no-op for them.
    let fileToStop = project.file
    for k in ls.projectFiles.keys.toSeq:
      if ls.projectFiles.hasKey(k) and ls.projectFiles[k].file == fileToStop:
        ls.projectFiles.del(k)

    ls.showMessage(
      fmt"Nimsuggest for {project.file} was stopped because it was idle for too long",
      MessageType.Info,
    )

