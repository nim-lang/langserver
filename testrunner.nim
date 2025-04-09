import std/[os, osproc, strscans, tables, sequtils, enumerate, strutils]
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

proc listTestsForEntryPoint*(
    ls: LanguageServer, entryPoints: seq[string], nimPath: string
): Future[TestProjectInfo] {.async.} =
  #For now only one entry point is supported
  assert entryPoints.len == 1
  let entryPoint = entryPoints[0]
  if not fileExists(entryPoint):
    error "Entry point does not exist", entryPoint = entryPoint
    return TestProjectInfo()
  let process = await startProcess(
    nimPath,
    arguments = @["c", "-d:unittest2ListTests", "-r", "--listFullPaths", entryPoints[0]],
    options = {UsePath},
    stderrHandle = AsyncProcess.Pipe,
    stdoutHandle = AsyncProcess.Pipe,
  )
  try:
    let res = await process.waitForExit(15.seconds)
    if res != 0:
      error "Failed to list tests", nimPath = nimPath, entryPoint = entryPoints[0], res = res    
      error "An error occurred while listing tests", error = string.fromBytes(process.stderrStream.read().await)
    else:
      let rawOutput = string.fromBytes(process.stdoutStream.read().await)   
      result = extractTestInfo(rawOutput)
  finally:
    await shutdownChildProcess(process)
