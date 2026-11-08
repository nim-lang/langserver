import
  std/[json, os, osproc, tables, options],
  chronos,
  chronos/asyncproc,
  unittest2,
  ../[ls, testrunner],
  ./testhelpers

import ../routes/lsp as lspRoutes

suite "Test Parser":
  test "should be able to list tests from an entry point":
    #A project can have multiple entry points for the tests, they are specified in the test runner.
    #We first need to install the project, as it uses a custom version of unittest2 (until it get merged).
    let projectDir = os.getCurrentDir() / "tests" / "projects" / "testrunner"
    cd projectDir:
      let (output, _) = execNimble("install", "-l")
      discard execNimble("setup")
      let (listTestsOutput, _) =
        execCmdEx("nim c -d:unittest2ListTests -r ./tests/test1.nim")
      let testProjectInfo = extractTestInfo(listTestsOutput)
      check testProjectInfo.suites.len == 1
      check testProjectInfo.suites["test1.nim"].tests.len == 1
      check testProjectInfo.suites["test1.nim"].tests[0].name == "can add"
      check testProjectInfo.suites["test1.nim"].tests[0].file == "test1.nim"
      check testProjectInfo.suites["test1.nim"].tests[0].line == 10

  test "should be able to list tests and suites":
    let projectDir = os.getCurrentDir() / "tests" / "projects" / "testrunner"
    cd projectDir:
      let (listTestsOutput, _) =
        execCmdEx("nim c -d:unittest2ListTests -r ./tests/sampletests.nim")
      let testProjectInfo = extractTestInfo(listTestsOutput)
      check testProjectInfo.suites.len == 3
      check testProjectInfo.suites["Sample Tests"].tests.len == 1
      check testProjectInfo.suites["Sample Tests"].tests[0].name == "Sample Test alone"
      check testProjectInfo.suites["Sample Tests"].tests[0].file == "sampletests.nim"
      check testProjectInfo.suites["Sample Tests"].tests[0].line == 4
      check testProjectInfo.suites["Sample Suite"].tests.len == 3
      check testProjectInfo.suites["sampletests.nim"].tests.len == 3

suite "Test Runner":
  test "cancelling a running test stops it":
    let entryPoint =
      os.getCurrentDir() / "tests" / "projects" / "testrunner" / "tests" / "sampletests.nim"
    let ls = LanguageServer(initialized: true)
    let running = runTests(entryPoint, "nim", none(string), @[], @[], ls)
    check waitUntil(ls.testRunProcess.isSome)
    let process = ls.testRunProcess.get

    # the run is waiting for the process when it is cancelled
    check (waitFor lspRoutes.cancelTest(ls, newJObject())).cancelled
    check waitFor running.withTimeout(60.seconds)
    check process.running() == AsyncProcessResult[bool].ok(false)
    check ls.testRunProcess.isNone

  test "should be able to run tests and retrieve results":
    let entryPoint =
      os.getCurrentDir() / "tests" / "projects" / "testrunner" / "tests" / "sampletests.nim"
    let ls = LanguageServer()
    let testProjectResult =
      waitFor runTests(entryPoint, "nim", none(string), @[], @[], ls)
    check testProjectResult.suites.len == 4
    check testProjectResult.suites[0].name == "Sample Tests"
    check testProjectResult.suites[0].tests == 1
    check testProjectResult.suites[0].failures == 0
    check testProjectResult.suites[0].errors == 0
    check testProjectResult.suites[0].skipped == 0
    check testProjectResult.suites[0].time > 0.0 and
      testProjectResult.suites[0].time < 1.0
