import std/[options, os, strutils, strscans, json, tables, sequtils]
import chronos
import chronos/asyncproc
import chronicles
import stew/byteutils
import ../protocol/[types]
import ../langserver/langserver
import ../nimsuggest/nimsuggest
import ../nim_compiler/testrunner
import ../nim_compiler/nim_compiler
import ../utils/process_utils
import ../utils/utils

# === extension/macroExpand ===
proc expand*(ls: LanguageServer, params: JsonNode): Future[JsonNode] {.async.} =
  # TODO: implement macro expansion via nimExpandMacro
  return newJNull()

# === extension/status ===
proc status*(ls: LanguageServer, params: NimLangServerStatusParams): Future[NimLangServerStatus] {.async.} =
  return ls.getLspStatus()

# === extension/capabilities ===
proc extensionCapabilities*(ls: LanguageServer, params: JsonNode): Future[seq[LspExtensionCapability]] {.async.} =
  return @[excRestartSuggest, excNimbleTask, excRunTests]

# === extension/suggest ===
proc extensionSuggest*(ls: LanguageServer, params: SuggestParams): Future[SuggestResult] {.async.} =
  debug "extensionSuggest called", action = $params.action, projectFile = params.projectFile
  case params.action
  of saRestart:
    let projectFilePath = FilePath(params.projectFile)
    if ls.pool.slots.hasKey(projectFilePath):
      asyncSpawn restartSlot(ls.pool.slots[projectFilePath], ls.pool, ls.configurations.currentConfig)
    else:
      debug "extensionSuggest: no slot found for project", projectFile = params.projectFile
  of saRestartAll:
    ls.pool.restartAllNimsuggestInstances(ls.configurations.currentConfig)
  of saNone:
    discard
  return SuggestResult(actionPerformed: params.action)

proc startNimbleProcess(
  ls: LanguageServer, args: seq[string], workingDir: string = ""
): Future[AsyncProcessRef] {.async.} =
  let dir =
    if workingDir != "": workingDir
    else: ls.capabilities.lspInitializeParams.getRootPath
  let nimbleDirEnv = getEnv("NIMBLE_DIR", "<not set>")
  let homeEnv = getEnv("HOME", "<not set>")
  let pathEnv = getEnv("PATH", "<not set>")
  debug "startNimbleProcess environment",
    args = args,
    workingDir = dir,
    NIMBLE_DIR = nimbleDirEnv,
    HOME = homeEnv,
    PATH = pathEnv
  await startProcess(
    "nimble",
    arguments = args,
    options = {UsePath},
    workingDir = dir,
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

  # Find nimble directories: check the workspace root first, then one level deep.
  var nimbleDirs: seq[string]
  if walkFiles(rootPath / "*.nimble").toSeq.len > 0:
    nimbleDirs.add(rootPath)
  else:
    for entry in walkDir(rootPath):
      if entry.kind == pcDir:
        if walkFiles(entry.path / "*.nimble").toSeq.len > 0:
          nimbleDirs.add(entry.path)

  if nimbleDirs.len == 0:
    warn "No .nimble files found in workspace root or immediate subdirectories",
      rootPath = rootPath
    return @[]

  for dir in nimbleDirs:
    debug "Running nimble tasks in directory", dir = dir
    let process = await ls.startNimbleProcess(@["tasks"], workingDir = dir)
    let exitCode = await process.waitForExit(InfiniteDuration)
    if exitCode != 0:
      warn "nimble tasks failed", dir = dir, exitCode = exitCode
      await process.shutdownChildProcess()
      continue
    let output = string.fromBytes(await process.stdoutStream.read())
    var name, desc: string
    for line in output.splitLines:
      if scanf(line, "$+  $*", name, desc):
        #first run of nimble tasks can compile nim and output the result of the compilation
        if name.isWord:
          result.add NimbleTask(
            name: name.strip(), description: desc.strip(), projectDir: dir
          )
    await process.shutdownChildProcess()

# === extension/runTask ===
proc runTask*(
    ls: LanguageServer, params: RunTaskParams
): Future[RunTaskResult] {.async.} =
  let process = await ls.startNimbleProcess(params.command, workingDir = params.workingDir)
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
  let config = ls.configurations.currentConfig
  let nimPath = config.getNimPath()
  if nimPath.isNone:
    error "Nim path not found when listing tests"
    return ListTestsResult(
      projectInfo: TestProjectInfo(
        entryPoint: params.entryPoint, suites: initTable[string, TestSuiteInfo]()
      )
    )
  let workspaceRoot = ls.capabilities.lspInitializeParams.getRootPath
  let testProjectInfo = await listTests(params.entryPoint, nimPath.get(), workspaceRoot)
  result.projectInfo = testProjectInfo

# === extension/runTest === 
proc runTests*(
    ls: LanguageServer, params: RunTestParams
): Future[RunTestProjectResult] {.async.} =
  let config = ls.configurations.currentConfig
  let nimPath = getNimPath(config)
  if nimPath.isNone:
    error "Nim path not found when running tests"
    return RunTestProjectResult()
  let workspaceRoot = ls.capabilities.lspInitializeParams.getRootPath
  await runTests(
    params.entryPoint,
    nimPath.get(),
    params.suiteName,
    params.testNames,
    workspaceRoot,
    ls,
  )

# === extension/cancelTest === 
proc cancelTest*(
    ls: LanguageServer, params: JsonNode
): Future[CancelTestResult] {.async.} =
  debug "Cancelling test"
  if ls.testRunProcess.isSome:
    await shutdownChildProcess(ls.testRunProcess.get)
    ls.testRunProcess = none(AsyncProcessRef)
    return CancelTestResult(cancelled: true)
  return CancelTestResult(cancelled: false)

# === extension/recompile === 
# === extension/restartServer === 

# TODO
