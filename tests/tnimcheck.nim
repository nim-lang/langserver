import ../nimcheck
import std/strutils
import unittest2

suite "nim check's output":
  test "each diagnostic gets its own lines, and nim's own messages none":
    let output = """
Hint: used config file '/nim/config/nim.cfg' [Conf]
.................................................
/p/m.nim(3, 2) Error: type mismatch
Expression: f(1)
  [1] 1: int literal(1)

Expected one of (first mismatch at [position]):
[1] proc f(x: string)

/p/m.nim(6, 2) template/generic instantiation of `g` from here
/p/m.nim(5, 16) Error: type mismatch: got 'string' for 'x' but expected 'int'
/p/m.nim(5, 7) Hint: 'y' is declared but not used [XDeclaredButNotUsed]
/p/m.nim(1, 12) Warning: imported and not used: 'macros' [UnusedImport]
Hint: mm: orc; threads: on; opt: none (DEBUG BUILD, `-d:release` generates faster code)
Hint: 128011 lines; 0.475s; 177.652MiB peakmem; proj: /p/m.nim; out: unknownOutput [SuccessX]
""".splitLines()
    let r = parseCheckResults(output)
    check r.len == 4

    check r[0].line == 3 and r[0].column == 2 and r[0].severity == "Error"
    check r[0].msg.startsWith("type mismatch\nExpression: f(1)")
    check "[1] proc f(x: string)" in r[0].msg
    check "instantiation" notin r[0].msg

    # the instantiation that comes before it
    check r[1].line == 5 and r[1].msg.startsWith("type mismatch: got 'string'")
    check "instantiation of `g` from here" in r[1].msg

    check r[2].msg == "'y' is declared but not used [XDeclaredButNotUsed]"
    check r[3].severity == "Warning"
    check r[3].msg == "imported and not used: 'macros' [UnusedImport]"
