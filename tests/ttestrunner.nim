import unittest
import std/[os, tables]
import testparser

suite "Test Parser":
  test "should be able to retrieve a test from a file":
    let file = getCurrentDir() / "tests" / "projects" / "testproject" / "tests" / "test1.nim"
    check fileExists(file)
    let testInfo = extractTestInfo(file)
    # echo testInfo
    check testInfo.suites.len == 1
    check testInfo.suites[""].tests.len == 1
    check testInfo.suites[""].tests[0].name == "can add"
    check testInfo.suites[""].tests[0].line == 11

  test "should be able to retrieve suites and tests from a file":
    let file = getCurrentDir() / "tests" / "projects" / "testproject" / "tests" / "testwithsuite.nim"
    if not fileExists(file):
      echo "File does not exist " & file
      echo getCurrentDir()
      echo "Does exists as relative?", fileExists("./" & "tests" / "projects" / "testproject" / "tests" / "testwithsuite.nim")
      let dir = getCurrentDir() / "tests" / "projects" / "testproject" / "tests"
      echo "Walking dir: ", dir, "dir exists? ", dirExists(dir)
      for f in dir.walkDir():
        echo f.path
    check fileExists(file)
    let testInfo = extractTestInfo(file)
    # echo testInfo
    check testInfo.suites.len == 3 # 2 suites and 1 test global
    check testInfo.suites["test suite"].tests.len == 3
    check testInfo.suites["test suite 2"].tests.len == 2
    check testInfo.suites[""].tests.len == 1

