import
  ../suggestapi, unittest, os, faststreams/async_backend, std/asyncnet, asyncdispatch, utils, strformat

const
  expected = "proc ()" & defaultPragmas
  inputLine = &"def	skProc	hw.a	proc (){defaultPragmas}	hw/hw.nim	1	5	\"\"	100"

suite "Nimsuggest tests":
  let
    helloWorldFile = getCurrentDir() / "tests/projects/hw/hw.nim"
    nimSuggest = createNimsuggest(helloWorldFile).waitFor

  test "Parsing qualified path":
    doAssert parseQualifiedPath("a.b.c") == @["a", "b", "c"]
    doAssert parseQualifiedPath("system.`..<`") == @["system", "`..<`"]

  test "Parsing Suggest":
    check parseSuggest(inputLine)[] == Suggest(
      filePath: "hw/hw.nim",
      qualifiedPath: @["hw", "a"],
      symKind: "skProc",
      line: 1,
      column: 5,
      doc: "",
      forth: expected,
      section: ideDef)[]

  test "test Nimsuggest.call":
    let res = waitFor nimSuggest.call("def", helloWorldFile, helloWorldFile, 2, 0)
    doAssert res.len == 1
    doAssert res[0].forth == expected

  test "test Nimsuggest.def":
    let res = waitFor nimSuggest.def(helloWorldFile, helloWorldFile, 2, 0)
    doAssert res.len == 1
    doAssert res[0].forth == expected

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
