import std/macros

macro myMacro(body: untyped): untyped =
  result = newStmtList()
  result.add(newCall(ident"echo", newLit("expanded!")))

myMacro:
  discard

echo "hello"
