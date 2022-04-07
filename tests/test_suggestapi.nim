import
  ../suggestapi, unittest, os, faststreams/async_backend, std/asyncnet, asyncdispatch

const inputLine = "def	skProc	hw.a	proc (){.noSideEffect, gcsafe, locks: 0.}	hw/hw.nim	1	5	\"\"	100"

suite "Nimsuggest tests":
  let
    helloWorldFile = getCurrentDir() / "tests/projects/hw/hw.nim"
    nimSuggest = createNimsuggest(helloWorldFile).waitFor

  test "Parsing qualified path":
    doAssert parseQualifiedPath("a.b.c") == @["a", "b", "c"]
    doAssert parseQualifiedPath("system.`..<`") == @["system", "`..<`"]

  test "Parsing Suggest":
    doAssert parseSuggest(inputLine)[] == Suggest(
      filePath: "hw/hw.nim",
      qualifiedPath: @["hw", "a"],
      symKind: "skProc",
      line: 1,
      column: 5,
      doc: "",
      forth: "proc (){.noSideEffect, gcsafe, locks: 0.}",
      section: ideDef)[]

  test "test Nimsuggest.call":
    let res = waitFor nimSuggest.call("def", helloWorldFile, helloWorldFile, 2, 0)
    doAssert res.len == 1
    doAssert res[0].forth == "proc (){.noSideEffect, gcsafe, locks: 0.}"

  test "test Nimsuggest.def":
    let res = waitFor nimSuggest.def(helloWorldFile, helloWorldFile, 2, 0)
    doAssert res.len == 1
    doAssert res[0].forth == "proc (){.noSideEffect, gcsafe, locks: 0.}"

  test "test Nimsuggest.sug":
    let res = waitFor nimSuggest.sug(helloWorldFile, helloWorldFile, 2, 0)
    doAssert res.len > 1
    doAssert res[0].forth == "proc ()"

  # test "test Nimsuggest.chk cancel more than one":
  #   let
  #     res1 = nimSuggest.chk(helloWorldFile, helloWorldFile)
  #     res2 = nimSuggest.chk(helloWorldFile, helloWorldFile)
  #   doAssert res1.waitFor.len == 2
  #   doAssert res2.waitFor.len == 0
