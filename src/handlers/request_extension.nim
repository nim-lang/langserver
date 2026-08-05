# === extension/macroExpand === 
# === extension/status === 
# === extension/capabilities === 
# === extension/suggest ===
# === extension/tasks === 

proc startNimbleProcess(
  ls: LanguageServer, args: seq[string]
): Future[AsyncProcessRef] {.async.} =
  let nimbleDirEnv = getEnv("NIMBLE_DIR", "<not set>")
  let homeEnv = getEnv("HOME", "<not set>")
  let pathEnv = getEnv("PATH", "<not set>")
  debug "startNimbleProcess environment",
    args = args,
    workingDir = ls.capabilities.lspInitializeParams.getRootPath,
    NIMBLE_DIR = nimbleDirEnv,
    HOME = homeEnv,
    PATH = pathEnv
  await startProcess(
    "nimble",
    arguments = args,
    options = {UsePath},
    workingDir = ls.capabilities.lspInitializeParams.getRootPath,
    stdoutHandle = AsyncProcess.Pipe,
    stderrHandle = AsyncProcess.Pipe,
  )

proc tasks*(ls: LanguageServer, conf: JsonNode): Future[seq[NimbleTask]] {.async.} =
  let rootPath: string = ls.capabilities.lspInitializeParams.getRootPath
  debug "Received tasks ", rootPath = rootPath
  debug "tasks: deleting NIMBLE_DIR before nimble tasks",
    NIMBLE_DIR_before = getEnv("NIMBLE_DIR", "<not set>"),
    HOME = getEnv("HOME", "<not set>")
  delEnv "NIMBLE_DIR"
  let process = await ls.startNimbleProcess(@["tasks"])
  let exitCode = await process.waitForExit(InfiniteDuration)
  if exitCode != 0:
    warn "nimble tasks failed", exitCode = exitCode
    ls.showMessage(
      "Failed to list nimble tasks (exit code " & $exitCode &
        "). Check that a .nimble file exists in the project root.",
      MessageType.Warning,
    )
    await process.shutdownChildProcess()
    return @[]
  let output = await process.stdoutStream.readLine()
  var name, desc: string
  for line in output.splitLines:
    if scanf(line, "$+  $*", name, desc):
      #first run of nimble tasks can compile nim and output the result of the compilation
      if name.isWord:
        result.add NimbleTask(name: name.strip(), description: desc.strip())
  await process.shutdownChildProcess()

# === extension/runTask ===
proc runTask*(
    ls: LanguageServer, params: RunTaskParams
): Future[RunTaskResult] {.async.} =
  let process = await ls.startNimbleProcess(params.command)
  let res = await process.waitForExit(InfiniteDuration)
  result.command = params.command
  let prefix = "\""
  while not process.stdoutStream.atEof():
    var lines = process.stdoutStream.readLine().await.splitLines
    for line in lines.mitems:
      if line.startsWith(prefix):
        line = line.unescape(prefix)
      if line != "":
        result.output.add line

  debug "Ran nimble cmd/task", command = $params.command, output = $result.output
  await process.shutdownChildProcess()

# === extension/listTests === 
proc listTests*(
    ls: LanguageServer, params: ListTestsParams
): Future[ListTestsResult] {.async.} =
  let config = ls.getWorkspaceConfiguration()
  let nimPath = config.getNimPath()
  if nimPath.isNone:
    error "Nim path not found when listing tests"
    return ListTestsResult(
      projectInfo: TestProjectInfo(
        entryPoint: params.entryPoint.get(""), suites: initTable[string, TestSuiteInfo]()
      )
    )
  let workspaceRoot = ls.capabilities.lspInitializeParams.getRootPath
  let testProjectInfo = await listTests(params.entryPoint.get(""), nimPath.get(), workspaceRoot)
  result.projectInfo = testProjectInfo

# === extension/runTest === 
proc runTests*(
    ls: LanguageServer, params: RunTestParams
): Future[RunTestProjectResult] {.async.} =
  let config = ls.getWorkspaceConfiguration()
  let nimPath = config.getNimPath()
  if nimPath.isNone:
    error "Nim path not found when running tests"
    return RunTestProjectResult()
  let workspaceRoot = ls.capabilities.lspInitializeParams.getRootPath
  await runTests(
    params.entryPoint,
    nimPath.get(),
    params.suiteName,
    params.testNames.get(@[]),
    workspaceRoot,
    ls,
  )
# === extension/cancelTest === 
proc cancelTest*(
    ls: LanguageServer, params: JsonNode
): Future[CancelTestResult] {.async.} =
  debug "Cancelling test"
  if ls.testRunProcess.isSome:
    #No need to cancel the runTests request. The client should handle it.
    await shutdownChildProcess(ls.testRunProcess.get)
    ls.testRunProcess = none(AsyncProcessRef)
    CancelTestResult(cancelled: true)
  else:
    CancelTestResult(cancelled: false)

