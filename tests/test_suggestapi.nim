import
  ../suggestapi, unittest, os

const inputLine = "def	skProc	hw.a	proc (){.noSideEffect, gcsafe, locks: 0.}	hw/hw.nim	1	5	\"\"	100"

suite "SuggestApi tests":
  test "Parsing Suggest":
    assert parseSuggest(inputLine)[] == Suggest(
      filePath: "hw/hw.nim",
      line: 1,
      column: 5,
      doc: "\"\"",
      forth: "proc (){.noSideEffect, gcsafe, locks: 0.}",
      section: ideDef)[]

  test "call method":
    let
      fileToTest = getCurrentDir() / "tests/projects/hw/hw.nim"
      dirtyFile = getCurrentDir() / "tests/projects/hw/hw.nim"
      nimSuggest = createSuggestApi("nimsuggest --find projects/hw/hw.nim --autobind")
      res = call(nimSuggest, "def", fileToTest, dirtyFile, 2, 0)
    assert res.len == 1
    assert res[0].forth == "proc (){.noSideEffect, gcsafe, locks: 0.}"
