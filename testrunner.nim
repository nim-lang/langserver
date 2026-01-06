import
  std/
    [os, strscans, tables, enumerate, strutils, xmlparser, xmltree, options, strformat]
import chronos, chronos/asyncproc
import protocol/types
import ls
import chronicles
import stew/byteutils
import utils

proc extractTestInfo*(rawOutput: string): TestProjectInfo =
  result.suites = initTable[string, TestSuiteInfo]()
  let lines = rawOutput.split("\n")
  var currentSuite = ""
  for i, line in enumerate(lines):
    var name, file, ignore: string
    var lineNumber: int
    if scanf(line, "Suite: $*", name):
      currentSuite = name.strip()
      result.suites[currentSuite] = TestSuiteInfo(name: currentSuite)
      # echo "Found suite: ", currentSuite
    elif scanf(line, "$*Test: $*", ignore, name):
      let insideSuite = line.startsWith("\t")
      # Use currentSuite if inside a suite, empty string if not
      let suiteName = if insideSuite: currentSuite else: ""

      #File is always next line of a test
      if scanf(lines[i + 1], "$*File:$*:$i", ignore, file, lineNumber):
        var testInfo =
          TestInfo(name: name.strip(), file: file.strip(), line: lineNumber)
        # echo "Adding test: ", testInfo.name, " to suite: ", suiteName
        result.suites[suiteName].tests.add(testInfo)

proc getFullPath*(entryPoint: string, workspaceRoot: string): string =
  if not fileExists(entryPoint):
    let absolutePath = joinPath(workspaceRoot, entryPoint)
    if fileExists(absolutePath):
      return absolutePath
  return entryPoint

proc parseObject(obj: var object, node: XmlNode) =
  for field, value in obj.fieldPairs:
    when value is string:
      getField(obj, field) = node.attr(field)
    elif value is int:
      getField(obj, field) = parseInt(node.attr(field))
    elif value is float:
      getField(obj, field) = parseFloat(node.attr(field))

proc parseTestResult*(node: XmlNode): RunTestResult =
  parseObject(result, node)
  # Add handling for failure node
  let failureNode = node.child("failure")
  if not failureNode.isNil:
    result.failure = some failureNode.attr("message")

proc parseTestSuite*(node: XmlNode): RunTestSuiteResult =
  parseObject(result, node)
  for testCase in node.findAll("testcase"):
    result.testResults.add(parseTestResult(testCase))

proc parseTestResults*(xmlContent: string): RunTestProjectResult =
  let xml = parseXml(xmlContent)
  for suiteNode in xml.findAll("testsuite"):
    let suite = parseTestSuite(suiteNode)
    # echo suite.name, " ", suite.testResults.len
    if suite.testResults.len > 0:
      result.suites.add(suite)

proc listTests*(
    entryPoint: string, nimPath: string, workspaceRoot: string
): Future[TestProjectInfo] {.async.} =
  var entryPoint = getFullPath(entryPoint, workspaceRoot)
  let executableDir = (getTempDir() / entryPoint.splitFile.name).absolutePath
  debug "Listing tests", entryPoint = entryPoint, exists = fileExists(entryPoint)
  let args =
    @["c", "--outdir:" & executableDir, "-d:unittest2ListTests", "-r", entryPoint]
  let process = await startProcess(
    nimPath,
    arguments = args,
    options = {UsePath},
    stderrHandle = AsyncProcess.Pipe,
    stdoutHandle = AsyncProcess.Pipe,
  )
  try:
    let (error, res) = await readErrorOutputUntilExit(process, 15.seconds)
    if res != 0:
      result = extractTestInfo(error)
      if result.suites.len == 0:
        error "Failed to list tests",
          nimPath = nimPath, entryPoint = entryPoint, res = res
        error "An error occurred while listing tests"
        for line in error.splitLines:
          error "Error line: ", line = line
        error "Command args: ", args = args
        result = TestProjectInfo(error: some error)
    else:
      let rawOutput = await process.stdoutStream.readAllOutput()
      debug "list test raw output", rawOutput = rawOutput
      result = extractTestInfo(rawOutput)
  finally:
    await shutdownChildProcess(process)

proc runTests*(
    entryPoint: string,
    nimPath: string,
    suiteName: Option[string],
    testNames: seq[string],
    workspaceRoot: string,
    ls: LanguageServer,
): Future[RunTestProjectResult] {.async.} =
  var entryPoint = getFullPath(entryPoint, workspaceRoot)
  if not fileExists(entryPoint):
    error "Entry point does not exist", entryPoint = entryPoint
    return RunTestProjectResult()
  let resultFile = (getTempDir() / "result.xml").absolutePath
  removeFile(resultFile)
  let executableDir = (getTempDir() / entryPoint.splitFile.name).absolutePath
  var args =
    @["c", "--outdir:" & executableDir, "-r", entryPoint, fmt"--xml:{resultFile}"]
  if suiteName.isSome:
    args.add(fmt"{suiteName.get()}::")
  else:
    for testName in testNames:
      args.add(testName)

  let process = await startProcess(
    nimPath,
    arguments = args,
    options = {UsePath},
    stderrHandle = AsyncProcess.Pipe,
    stdoutHandle = AsyncProcess.Pipe,
  )
  ls.testRunProcess = some(process)
  try:
    let (error, res) = await readErrorOutputUntilExit(process, 15.seconds)
    if res != 0: #When a test fails, the process will exit with a non-zero code
      if fileExists(resultFile):
        result = parseTestResults(readFile(resultFile))
        result.fullOutput = error
        return result

      error "Failed to run tests", nimPath = nimPath, entryPoint = entryPoint, res = res
      error "An error occurred while running tests"
      error "Error from process", error = error
      result = RunTestProjectResult(fullOutput: error)
      result.fullOutput = error
    else:
      let output = await process.stdoutStream.readAllOutput()
      let xmlContent = readFile(resultFile)
      # echo "XML CONTENT: ", xmlContent
      result = parseTestResults(xmlContent)
      result.fullOutput = output
  except Exception as e:
    let processOutput = string.fromBytes(process.stdoutStream.read().await)
    error "An error occurred while running tests", error = e.msg
    error "Output from process", output = processOutput
  finally:
    removeFile(resultFile)
    await shutdownChildProcess(process)
    if ls.testRunProcess.isSome:
      ls.testRunProcess = none(AsyncProcessRef)
