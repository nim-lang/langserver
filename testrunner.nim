import std/[os, strscans, tables, enumerate, strutils, xmlparser, xmltree, options, strformat]
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
      if scanf(lines[i+1], "$*File:$*:$i", ignore, file, lineNumber):
        var testInfo = TestInfo(name: name.strip(), file: file.strip(), line: lineNumber)
        # echo "Adding test: ", testInfo.name, " to suite: ", suiteName
        result.suites[suiteName].tests.add(testInfo)

proc getFullPath*(entryPoint: string, workspaceRoot: string): string =
  if not fileExists(entryPoint):
    let absolutePath = joinPath(workspaceRoot, entryPoint)
    if fileExists(absolutePath):
      return absolutePath
  return entryPoint

proc listTests*(
  entryPoints: seq[string], 
  nimPath: string,
  workspaceRoot: string
): Future[TestProjectInfo] {.async.} =
  assert entryPoints.len == 1
  var entryPoint = getFullPath(entryPoints[0], workspaceRoot)
  let process = await startProcess(
    nimPath,
    arguments = @["c", "-d:unittest2ListTests", "-r", "--listFullPaths", entryPoint],
    options = {UsePath},
    stderrHandle = AsyncProcess.Pipe,
    stdoutHandle = AsyncProcess.Pipe,
  )
  try:
    let res = await process.waitForExit(15.seconds)
    if res != 0:
      error "Failed to list tests", nimPath = nimPath, entryPoint = entryPoint, res = res    
      error "An error occurred while listing tests", error = string.fromBytes(process.stderrStream.read().await)
    else:
      let rawOutput = string.fromBytes(process.stdoutStream.read().await)   
      result = extractTestInfo(rawOutput)
  finally:
    await shutdownChildProcess(process)

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

proc runTests*(
  entryPoints: seq[string], 
  nimPath: string, 
  suiteName: Option[string], 
  testNames: seq[string],
  workspaceRoot: string
): Future[RunTestProjectResult] {.async.} =
  assert entryPoints.len == 1
  var entryPoint = getFullPath(entryPoints[0], workspaceRoot)
  if not fileExists(entryPoint):
    error "Entry point does not exist", entryPoint = entryPoint    
    return RunTestProjectResult()
  let resultFile = (getTempDir() / "result.xml").absolutePath        
  var args = @["c", "-r", entryPoint , fmt"--xml:{resultFile}"]
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
  try:
    let res = await process.waitForExit(15.seconds)
    if not fileExists(resultFile):
      let processOutput = string.fromBytes(process.stdoutStream.read().await)
      let processError = string.fromBytes(process.stderrStream.read().await)
      error "Result file does not exist meaning tests were not run"
      error "Output from process", output = processOutput
      error "Error from process", error = processError
    else:
      let xmlContent = readFile(resultFile)
      # echo "XML CONTENT: ", xmlContent
      result = parseTestResults(xmlContent)
      removeFile(resultFile)
  except Exception as e:
    let processOutput = string.fromBytes(process.stdoutStream.read().await)
    error "An error occurred while running tests", error = e.msg
    error "Output from process", output = processOutput
  finally:
    await shutdownChildProcess(process)
  