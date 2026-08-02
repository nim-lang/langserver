import ../ls
import ../suggestapi
import std/[os, times, options, tables]
import chronos
import unittest2

suite "extractCrashedFile":
  test "extracts first quoted path from a sug command":
    check extractCrashedFile(
      "sug \"/path/to/file.nim\";\"/tmp/stash.nim\":4:1"
    ) == "/path/to/file.nim"

  test "extracts path from a def command":
    check extractCrashedFile(
      "def \"/Users/foo/bar.nim\":10:5"
    ) == "/Users/foo/bar.nim"

  test "returns empty string when no quotes present":
    check extractCrashedFile("sug noQuotesHere") == ""

  test "returns empty string for empty input":
    check extractCrashedFile("") == ""

  test "handles path with spaces":
    check extractCrashedFile(
      "sug \"/Users/my user/project/file.nim\":1:0"
    ) == "/Users/my user/project/file.nim"

suite "findNimblePaths":
  let tmpRoot = getTempDir() / "nimble_paths_test_" & $getCurrentProcessId()

  setup:
    createDir(tmpRoot / "subdir")

  teardown:
    removeDir(tmpRoot)

  test "finds nimble.paths one level up and returns its contents":
    writeFile(tmpRoot / "nimble.paths", "--noNimblePath\n--path:\"/some/dep\"\n")
    let result = findNimblePaths(tmpRoot / "subdir" / "test.nim")
    check "--noNimblePath" in result
    check "--path:/some/dep" in result

  test "strips quotes from --path:\"...\" entries":
    writeFile(tmpRoot / "nimble.paths", "--path:\"/quoted/path\"\n")
    let result = findNimblePaths(tmpRoot / "subdir" / "test.nim")
    check "--path:/quoted/path" in result
    check "--path:\"/quoted/path\"" notin result

  test "returns empty seq when no nimble.paths exists anywhere":
    let result = findNimblePaths(tmpRoot / "subdir" / "test.nim")
    check result.len == 0

  test "finds nimble.paths at the exact parent directory (one hop)":
    writeFile(tmpRoot / "nimble.paths", "--noNimblePath\n")
    let result = findNimblePaths(tmpRoot / "subdir" / "test.nim")
    check result.len == 1
    check result[0] == "--noNimblePath"

  test "skips blank lines in nimble.paths":
    writeFile(tmpRoot / "nimble.paths", "\n--noNimblePath\n\n--path:\"/a\"\n\n")
    let result = findNimblePaths(tmpRoot / "subdir" / "test.nim")
    check result.len == 2
    check result[0] == "--noNimblePath"
    check result[1] == "--path:/a"

suite "leastRecentlyUsedProjectFile":

  proc makeFinishedProject(file: string, date: DateTime): Project =
    let fut = newFuture[NimSuggest]("test")
    fut.complete(nil)
    Project(file: file, ns: fut, lastCmdDate: some(date))

  proc makePendingProject(file: string): Project =
    Project(file: file, ns: newFuture[NimSuggest]("test"))

  test "returns the project with the oldest lastCmdDate":
    let ls = LanguageServer()
    let old = dateTime(2024, mJan, 1, 0, 0, 0, 0, utc())
    let recent = dateTime(2024, mJun, 1, 0, 0, 0, 0, utc())
    ls.projectFiles["old.nim"] = makeFinishedProject("old.nim", old)
    ls.projectFiles["recent.nim"] = makeFinishedProject("recent.nim", recent)
    check leastRecentlyUsedProjectFile(ls) == "old.nim"

  test "falls back to first key when no finished instances exist":
    let ls = LanguageServer()
    ls.projectFiles["first.nim"] = makePendingProject("first.nim")
    ls.projectFiles["second.nim"] = makePendingProject("second.nim")
    let result = leastRecentlyUsedProjectFile(ls)
    check result in ["first.nim", "second.nim"]

  test "ignores pending instances and picks oldest among finished ones":
    let ls = LanguageServer()
    let old = dateTime(2024, mJan, 1, 0, 0, 0, 0, utc())
    ls.projectFiles["pending.nim"] = makePendingProject("pending.nim")
    ls.projectFiles["old.nim"] = makeFinishedProject("old.nim", old)
    check leastRecentlyUsedProjectFile(ls) == "old.nim"

  test "handles a project with no lastCmdDate (treated as epoch)":
    let ls = LanguageServer()
    let fut = newFuture[NimSuggest]("test")
    fut.complete(nil)
    ls.projectFiles["nodate.nim"] = Project(file: "nodate.nim", ns: fut)
    let recent = dateTime(2024, mJun, 1, 0, 0, 0, 0, utc())
    ls.projectFiles["recent.nim"] = makeFinishedProject("recent.nim", recent)
    check leastRecentlyUsedProjectFile(ls) == "nodate.nim"
