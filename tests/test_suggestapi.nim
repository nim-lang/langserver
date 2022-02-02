import
  ../suggestapi, unittest, os, faststreams/async_backend, std/asyncnet, asyncdispatch

const inputLine = "def	skProc	hw.a	proc (){.noSideEffect, gcsafe, locks: 0.}	hw/hw.nim	1	5	\"\"	100"

suite "SuggestApi tests":
  let
    helloWorldFile = getCurrentDir() / "tests/projects/hw/hw.nim"
    nimSuggest = createSuggestApi(helloWorldFile)

  test "Parsing Suggest":
    # TODO handle multiline docs
    doAssert parseSuggest(inputLine)[] == Suggest(
      filePath: "hw/hw.nim",
      qualifiedPath: @["hw", "a"],
      symKind: "skProc",
      line: 1,
      column: 5,
      doc: "",
      forth: "proc (){.noSideEffect, gcsafe, locks: 0.}",
      section: ideDef)[]

  test "test SuggestApi.call":
    let res = waitFor nimSuggest.call("def", helloWorldFile, helloWorldFile, 2, 0)
    doAssert res.len == 1
    doAssert res[0].forth == "proc (){.noSideEffect, gcsafe, locks: 0.}"

  test "test SuggestApi.def":
    let res = waitFor nimSuggest.def(helloWorldFile, helloWorldFile, 2, 0)
    doAssert res.len == 1
    doAssert res[0].forth == "proc (){.noSideEffect, gcsafe, locks: 0.}"

  test "test SuggestApi.sug":
    let res = waitFor nimSuggest.sug(helloWorldFile, helloWorldFile, 2, 0)
    doAssert res.len > 1
    doAssert res[0].forth == "proc ()"

  # test "test SuggestApi.def":
  #   let res = waitFor nimSuggest.def(helloWorldFile, helloWorldFile, 4, 0)
  #   doAssert res.len == 1
  #   doAssert res[0].doc == "proc (){.noSideEffect, gcsafe, locks: 0.}"
