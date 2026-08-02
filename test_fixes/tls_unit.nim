import ../src/nimble/nimble
import std/[os, options]
import unittest2

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
