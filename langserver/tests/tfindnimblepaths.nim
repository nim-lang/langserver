## tfindnimblepaths.nim
## Unit tests for findNimblePaths in src/nimble/nimble.nim.
##
## Ported from test_fixes/tls_unit.nim with path updated for the new src/ layout.
## No running server required — findNimblePaths is a pure filesystem walk.
##
## Run with: nim c --path:. -r tests_rewrite/tfindnimblepaths.nim

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

  test "finds nimble.paths two levels up (deep subdirectory)":
    createDir(tmpRoot / "subdir" / "deeper")
    writeFile(tmpRoot / "nimble.paths", "--noNimblePath\n")
    let result = findNimblePaths(tmpRoot / "subdir" / "deeper" / "test.nim")
    check "--noNimblePath" in result

  test "nearest nimble.paths wins when multiple exist in ancestor chain":
    ## If there is a nimble.paths at /tmp/x/subdir/ AND one at /tmp/x/, the
    ## closer one (subdir) should be used — findNimblePaths stops at the first hit.
    createDir(tmpRoot / "subdir")
    writeFile(tmpRoot / "nimble.paths", "--path:\"/outer\"\n")
    writeFile(tmpRoot / "subdir" / "nimble.paths", "--path:\"/inner\"\n")
    let result = findNimblePaths(tmpRoot / "subdir" / "test.nim")
    check "--path:/inner" in result
    check "--path:/outer" notin result
