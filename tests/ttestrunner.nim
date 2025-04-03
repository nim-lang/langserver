import unittest
import std/[os, tables]
import testparser

suite "Test Parser":
  test "should be able to retrieve a test from a file":
    let file = getCurrentDir() / "tests" / "projects" / "testproject" / "tests" / "test1.nim"
    let testInfo = extractTestInfo(file)
    # echo testInfo
    check testInfo.suites.len == 1
    check testInfo.suites[""].tests.len == 1
    check testInfo.suites[""].tests[0].name == "can add"
    check testInfo.suites[""].tests[0].line == 11

  test "should be able to retrieve suites and tests from a file":
    let file = getCurrentDir() / "tests" / "projects" / "tasks" / "tests" / "testwithsuites.nim"
    let testInfo = extractTestInfo(file)
    # echo testInfo
    check testInfo.suites.len == 3 # 2 suites and 1 test global
    check testInfo.suites["test suite"].tests.len == 3
    check testInfo.suites["test suite 2"].tests.len == 2
    check testInfo.suites[""].tests.len == 1

