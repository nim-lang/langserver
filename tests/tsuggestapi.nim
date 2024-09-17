import
  ../suggestapi, unittest, os, std/asyncnet, strutils, chronos, options

const inputLine = "def	skProc	hw.a	proc (){.noSideEffect, gcsafe.}	hw/hw.nim	1	5	\"\"	100"
const inputLineWithEndLine = "outline	skEnumField	system.bool.true	bool	basic_types.nim	46	15	\"\"	100	4	11"

suite "Nimsuggest tests":
  let
    helloWorldFile = getCurrentDir() / "tests/projects/hw/hw.nim"
    nimSuggest = createNimsuggest(helloWorldFile).waitFor.ns.waitFor

  test "Parsing qualified path":
    doAssert parseQualifiedPath("a.b.c") == @["a", "b", "c"]
    doAssert parseQualifiedPath("system.`..<`") == @["system", "`..<`"]

  test "Parsing suggest":
    doAssert parseSuggestDef(inputLine).get[] == Suggest(
      filePath: "hw/hw.nim",
      qualifiedPath: @["hw", "a"],
      symKind: "skProc",
      line: 1,
      column: 5,
      doc: "",
      forth: "proc (){.noSideEffect, gcsafe.}",
      section: ideDef)[]

  test "Parsing suggest with endLine":
    let res = parseSuggestDef(inputLineWithEndLine).get
    doAssert res[] == Suggest(
      filePath: "basic_types.nim",
      qualifiedPath: @["system", "bool", "true"],
      symKind: "skEnumField",
      line: 46,
      column: 15,
      doc: "",
      forth: "bool",
      section: ideOutline,
      endLine: 4,
      endCol: 11
    )[]

  test "test Nimsuggest.call":
    let res = waitFor nimSuggest.call("def", helloWorldFile, helloWorldFile, 2, 0)
    doAssert res.len == 1
    doAssert res[0].forth.contains("noSideEffect")

  test "test Nimsuggest.def":
    let res = waitFor nimSuggest.def(helloWorldFile, helloWorldFile, 2, 0)
    doAssert res.len == 1
    doAssert res[0].forth.contains("proc")

  test "test Nimsuggest.sug":
    let res = waitFor nimSuggest.sug(helloWorldFile, helloWorldFile, 2, 0)
    doAssert res.len > 1
    doAssert res[0].forth == "proc ()"

  test "test Nimsuggest.known":
    let res = waitFor nimSuggest.known(helloWorldFile)
    doAssert res[0].forth == "true"

  # test "test Nimsuggest.chk cancel more than one":
  #   let
  #     res1 = nimSuggest.chk(helloWorldFile, helloWorldFile)
  #     res2 = nimSuggest.chk(helloWorldFile, helloWorldFile)
  #   doAssert res1.waitFor.len == 2
  #   doAssert res2.waitFor.len == 0
