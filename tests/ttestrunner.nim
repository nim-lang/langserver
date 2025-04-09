import unittest
import std/[os, osproc, strscans, tables, sequtils, enumerate, strutils]
import testhelpers

type
  TestInfo* = object
    name*: string
    line*: int
    file*: string
  
  TestSuiteInfo* = object
    name*: string #The suite name, empty if it's a global test
    tests*: seq[TestInfo]

  TestProjectInfo* = object
    entryPoints*: seq[string]
    suites*: Table[string, TestSuiteInfo]




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



suite "Test Parser":
  test "should be able to list tests from an entry point":
    #A project can have multiple entry points for the tests, they are specified in the test runner.
    #We first need to install the project, as it uses a custom version of unittest2 (until it get merged).
    let projectDir = getCurrentDir() / "tests" / "projects" / "testrunner"
    cd projectDir:
      let (output, _) = execNimble("install", "-l")
      discard execNimble("setup")
      let (listTestsOutput, _) = execCmdEx("nim c -d:unittest2ListTests -r ./tests/test1.nim")
      let testProjectInfo = extractTestInfo(listTestsOutput)
      echo testProjectInfo
      check testProjectInfo.suites.len == 1
      check testProjectInfo.suites["test1.nim"].tests.len == 1
      check testProjectInfo.suites["test1.nim"].tests[0].name == "can add"
      check testProjectInfo.suites["test1.nim"].tests[0].file == "test1.nim"
      check testProjectInfo.suites["test1.nim"].tests[0].line == 11

  test "should be able to list tests and suites":
    let projectDir = getCurrentDir() / "tests" / "projects" / "testrunner"
    cd projectDir:
      let (listTestsOutput, _) = execCmdEx("nim c -d:unittest2ListTests -r ./tests/sampletests.nim")
      let testProjectInfo = extractTestInfo(listTestsOutput)
      check testProjectInfo.suites.len == 3
      check testProjectInfo.suites["Sample Tests"].tests.len == 1
      check testProjectInfo.suites["Sample Tests"].tests[0].name == "Sample Test"
      check testProjectInfo.suites["Sample Tests"].tests[0].file == "sampletests.nim"
      check testProjectInfo.suites["Sample Tests"].tests[0].line == 4
      check testProjectInfo.suites["Sample Suite"].tests.len == 3
      check testProjectInfo.suites["sampletests.nim"].tests.len == 3
