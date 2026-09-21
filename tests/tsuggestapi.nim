import
  std/[os, strutils, options],
  chronos,
  chronos/asyncproc,
  unittest2,
  ../suggestapi,
  ./testhelpers

const inputLine =
  "def	skProc	hw.a	proc (){.noSideEffect, gcsafe.}	hw/hw.nim	1	5	\"\"	100"
const inputLineWithEndLine =
  "outline	skEnumField	system.bool.true	bool	basic_types.nim	46	15	\"\"	100	4	11"

suite "Nimsuggest tests":
  let
    helloWorldFile = getCurrentDir() / "tests/projects/hw/hw.nim"
    project = createNimsuggest(helloWorldFile).waitFor
    nimSuggest = project.ns

  suiteTeardown:
    project.stop()

  test "Parsing qualified path":
    check parseQualifiedPath("a.b.c") == @["a", "b", "c"]
    check parseQualifiedPath("system.`..<`") == @["system", "`..<`"]

  test "Parsing suggest":
    check parseSuggestDef(inputLine).get[] ==
      Suggest(
        filePath: "hw/hw.nim",
        qualifiedPath: @["hw", "a"],
        symkind: "skProc",
        line: 1,
        column: 5,
        doc: "",
        forth: "proc (){.noSideEffect, gcsafe.}",
        section: ideDef,
      )[]

  test "Parsing suggest with endLine":
    let res = parseSuggestDef(inputLineWithEndLine).get
    check res[] ==
      Suggest(
        filePath: "basic_types.nim",
        qualifiedPath: @["system", "bool", "true"],
        symkind: "skEnumField",
        line: 46,
        column: 15,
        doc: "",
        forth: "bool",
        section: ideOutline,
        endLine: 4,
        endCol: 11,
      )[]

  test "test Nimsuggest.call":
    let res = waitFor nimSuggest.call("def", helloWorldFile, helloWorldFile, 2, 10)
    check res.len == 1
    check res.len == 1 and res[0].forth.contains("noSideEffect")

  test "test Nimsuggest.def":
    let res = waitFor nimSuggest.def(helloWorldFile, helloWorldFile, 2, 10)
    check res.len == 1
    check res.len == 1 and res[0].forth.contains("proc")

  test "test Nimsuggest.sug":
    let res = waitFor nimSuggest.sug(helloWorldFile, helloWorldFile, 2, 0)
    check res.len > 1
    check res.len > 1 and res[0].forth == "proc ()"

  test "test Nimsuggest.known":
    let res = waitFor nimSuggest.known(helloWorldFile)
    check res.len >= 1 and res[0].forth == "true"

  # test "test Nimsuggest.chk cancel more than one":
  #   let
  #     res1 = nimSuggest.chk(helloWorldFile, helloWorldFile)
  #     res2 = nimSuggest.chk(helloWorldFile, helloWorldFile)
  #   check res1.waitFor.len == 2
  #   check res2.waitFor.len == 0

suite "Nimsuggest error handling":
  test "a dying nimsuggest fires the error callback exactly once":
    # Regression test for #428: markFailed fired errorCallback on every call,
    # so one crash triggered it once per failure path (closed socket in
    # processQueue + stderr EOF in logNsError) and the server restarted the
    # same project twice, concurrently. Suspend the child before issuing a
    # command so the command is in flight when the process is killed and both
    # paths run deterministically.
    let helloWorldFile = getCurrentDir() / "tests/projects/hw/hw.nim"
    let project = createNimsuggest(helloWorldFile).waitFor
    let ns = project.ns
    var errorCount = 0
    project.errorCallback = some(
      proc(pr: Project) {.async: (raises: []).} =
        inc errorCount
    )

    discard project.process.suspend()
    let fut = ns.def(helloWorldFile, helloWorldFile, 2, 10)
    waitFor sleepAsync(200)
    discard project.process.kill()

    expect CatchableError:
      discard waitFor fut

    check waitUntil(errorCount >= 1)
    check not waitUntil(errorCount > 1, timeout = 300.milliseconds)

  test "a nimsuggest cancelled during startup is marked failed":
    let helloWorldFile = getCurrentDir() / "tests/projects/hw/hw.nim"
    var failed = false
    let projectFut = createNimsuggest(
      helloWorldFile,
      "nimsuggest",
      "",
      REQUEST_TIMEOUT,
      proc(ns: Nimsuggest) {.async: (raises: []).} =
        discard,
      proc(pr: Project) {.async: (raises: []).} =
        failed = true,
    )

    waitFor projectFut.cancelAndWait()
    check projectFut.cancelled
    check failed
