import unittest
import std/[os, osproc, strscans, tables, sequtils, enumerate, strutils, options]
import testhelpers
import testrunner
import chronos

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
      check testProjectInfo.suites.len == 1
      check testProjectInfo.suites["test1.nim"].tests.len == 1
      check testProjectInfo.suites["test1.nim"].tests[0].name == "can add"
      check testProjectInfo.suites["test1.nim"].tests[0].file == "test1.nim"
      check testProjectInfo.suites["test1.nim"].tests[0].line == 10

  test "should be able to list tests and suites":
    let projectDir = getCurrentDir() / "tests" / "projects" / "testrunner"
    cd projectDir:
      let (listTestsOutput, _) = execCmdEx("nim c -d:unittest2ListTests -r ./tests/sampletests.nim")
      let testProjectInfo = extractTestInfo(listTestsOutput)
      check testProjectInfo.suites.len == 3
      check testProjectInfo.suites["Sample Tests"].tests.len == 1
      check testProjectInfo.suites["Sample Tests"].tests[0].name == "Sample Test alone"
      check testProjectInfo.suites["Sample Tests"].tests[0].file == "sampletests.nim"
      check testProjectInfo.suites["Sample Tests"].tests[0].line == 4
      check testProjectInfo.suites["Sample Suite"].tests.len == 3
      check testProjectInfo.suites["sampletests.nim"].tests.len == 3

suite "Test Runner":
  test "should be able to run tests and retrieve results":
    let entryPoint = getCurrentDir() / "tests" / "projects" / "testrunner" / "tests" / "sampletests.nim"
    let testProjectResult = waitFor runTests(@[entryPoint], "nim", none(string), @[])
    check testProjectResult.suites.len == 4
    check testProjectResult.suites[0].name == "Sample Tests"
    check testProjectResult.suites[0].tests == 1
    check testProjectResult.suites[0].failures == 0
    check testProjectResult.suites[0].errors == 0
    check testProjectResult.suites[0].skipped == 0
    check testProjectResult.suites[0].time > 0.0 and testProjectResult.suites[0].time < 1.0
