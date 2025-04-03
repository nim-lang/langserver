import std/[tables, options]
import compiler/[ast, idents, msgs, syntaxes, options, pathutils, lineinfos]
# import compiler/[renderer, astalgo]

type 
  TestInfo* = object
    name*: string
    line*: uint
  
  SuiteInfo* = object
    name*: string #empty means global suite
    tests*: seq[TestInfo]
    line*: uint

  TestFileInfo* = object
    testFile*: string
    suites*: Table[string, SuiteInfo]
    hasErrors*: bool

proc extractTest(n: PNode, conf: ConfigRef): Option[TestInfo] =
  if n.kind in nkCallKinds and 
     n[0].kind == nkIdent and 
     n[0].ident.s == "test":
    if n.len >= 2 and n[1].kind in {nkStrLit .. nkTripleStrLit}:
      return some(TestInfo(
        name: n[1].strVal,
        line: n.info.line
      ))
    else:
      localError(conf, n.info, "'test' requires a string literal name")
  return none(TestInfo)

proc extract(n: PNode, conf: ConfigRef, result: var TestFileInfo) =
  case n.kind
  of nkStmtList, nkStmtListExpr:
    for child in n:
      extract(child, conf, result)
  of nkCallKinds:
    if n[0].kind == nkIdent:
      case n[0].ident.s
      of "suite":
        if n.len >= 2 and n[1].kind in {nkStrLit .. nkTripleStrLit}:
          var suite = SuiteInfo(
            name: n[1].strVal, 
            tests: @[], 
            line: n.info.line
          )
          # Extract tests within the suite's body
          if n.len > 2 and n[2].kind == nkStmtList:
            for testNode in n[2]:
              let testInfo = extractTest(testNode, conf)
              if testInfo.isSome:
                suite.tests.add(testInfo.get)
          
          result.suites[suite.name] = suite
        else:
          localError(conf, n.info, "'suite' requires a string literal name")
          result.hasErrors = true
      of "test":
        # Handle top-level tests (not in a suite)
        let testInfo = extractTest(n, conf)
        if testInfo.isSome:
          result.suites.mgetOrPut("", SuiteInfo(
            name: "", 
            tests: @[],
            line: 0
          )).tests.add(testInfo.get)
      else:
        discard
  else:
    discard

proc extractTestInfo*(testFile: string): TestFileInfo =
  ## Extract test information from a test file. This parses the test file
  ## and extracts suite and test names.
  result.testFile = testFile
  var conf = newConfigRef()
  conf.foreignPackageNotes = {}
  conf.notes = {}
  conf.mainPackageNotes = {}
  conf.errorMax = high(int)
  conf.structuredErrorHook = proc(
      config: ConfigRef, info: TLineInfo, msg: string, severity: Severity
  ) {.gcsafe.} =
    localError(config, info, warnUser, msg)

  let fileIdx = fileInfoIdx(conf, AbsoluteFile testFile)
  var parser: Parser
  if setupParser(parser, fileIdx, newIdentCache(), conf):
    extract(parseAll(parser), conf, result)
    closeParser(parser)
  result.hasErrors = result.hasErrors or conf.errorCounter > 0

