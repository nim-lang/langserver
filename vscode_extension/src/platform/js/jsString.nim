## Original (MIT): https://github.com/treeform/jsutils/blob/master/src/jsutils/strings.nim
## JS Strings makes cstring have simmilar methods to normal nim string when in js mode.
## If you are doing with a ton of JS string data, JS strings might be faster

import jsre

when not defined(js) and not defined(Nimdoc):
  {.error: "This module only works on the JavaScript platform".}

proc `[]`*[T, U](s: cstring, x: HSlice[T, U]): cstring =
  ## Slices a JS string
  var l, h: int
  when T is BackwardsIndex:
    l = s.len - int(x.a)
  else:
    l = x.a
  when U is BackwardsIndex:
    h = s.len - int(x.b) + 1
  else:
    h = x.b + 1
  if h > s.len or l < 0:
    raise newException(IndexDefect, "index out of bounds []")

  asm """
  return `s`.slice(`l`, `h`);
  """

proc repeat*(s: cstring, n: Natural): cstring {.importcpp: "#.repeat(@)".}
  ## Returns string `s` concatenated `n` times.

proc startsWith*(s, a: cstring): bool {.importcpp: "#.startsWith(@)".}
  ## Returns true if ``s`` starts with string ``prefix``.
  ##
  ## If ``prefix == ""`` true is returned.

proc endsWith*(s: cstring, suffix: cstring): bool {.importcpp: "#.endsWith(@)".}
  ## Returns true if ``s`` ends with ``suffix``.
  ##
  ## If ``suffix == ""`` true is returned.

proc find*(s: cstring, a: cstring): cint {.importcpp: "#.indexOf(@)".}
  ## Searches for `a` in `s`.
  ##
  ## Searching is case-sensitive. If `a` is not in `s`, -1 is returned.

proc find*(s: cstring, a: RegExp): cint {.importcpp: "#.search(@)".}

proc match*(s: cstring, a: RegExp): seq[cstring] {.importcpp.}
  ## Retrieves the result of matching a string against a regular expression.

proc findLast*(s: cstring, a: cstring): cint {.importcpp: "#.lastIndexOf(@)".}
  ## Searches for `a` in `s`.
  ##
  ## Searching is case-sensitive. If `a` is not in `s`, -1 is returned.

proc contains*(s, sub: cstring): bool {.noSideEffect.} =
  ## Same as ``find(s, sub) >= 0``.
  ##
  ## See also:
  ## * `find proc<#find,string,string,Natural,int>`_
  return find(s, sub) >= 0

proc split*(s: cstring, a: cstring): seq[cstring] {.importcpp: "#.split(@)".}
  ## Splits the string `s` into substrings using a single separator.
  ##
  ## Substrings are separated by the character `sep`.

proc split*(s: cstring, a: RegExp): seq[cstring] {.importcpp: "#.split(@)".}
  ## Splits the string `s` into substrings using a regex separator.
  ##
  ## Substrings are separated by the character `sep`.

proc toLowerAscii*(s: cstring): cstring {.importcpp: "#.toLowerCase()".}
  ## Converts string `s` into lower case.
  ##
  ## This works only for the letters ``A-Z``.

proc toUpperAscii*(s: cstring): cstring {.importcpp: "#.toUpperCase()".}
  ## Converts string `s` into upper case.
  ##
  ## This works only for the letters ``A-Z``.

proc replace*(s, sub: cstring, by = cstring""): cstring {.importcpp: "#.replace(#, #)".}
  ## Replaces `sub` in `s` by the string `by`.

proc replace*(
  s: cstring, sub: RegExp, by = cstring""
): cstring {.importcpp: "#.replace(#, #)".} ## Replaces `sub` in `s` by the string `by`.

proc strip*(s: cstring): cstring {.importcpp: "#.trim()".}
  ## Strips leading or trailing spaces

proc parseFloatJS*(s: cstring): float {.importcpp: "parseFloat(@)".}
  ## Parses a decimal floating point value contained in `s`
  ## Using JS's native float parsing function

proc parseCint*(s: cstring): cint {.importcpp: "parseInt(@)".}
  ## Parses an int value contained in `s`
  ## Using JS's native float parsing function

proc parseCint*(s: cstring, radix: cint): cint {.importcpp: "parseInt(@)".}
  ## Parses an int value contained in `s` with the given radix
  ## Using JS's native float parsing function

proc join*(s: seq[cstring], sep: cstring): cstring {.importcpp: "#.join(@)".}
  ## Join an array of strings into a single string

proc toString*(i: int): cstring {.importcpp: "(#.toString(@))".}
  ## Convert an int to a string

proc toString*(i: int, radix: Natural): cstring {.importcpp: "(#.toString(@))".}
  ## Convert an int to a string given a radix

when isMainModule:
  import math
  import jsffi

  let
    a = cstring "hello "
    b = cstring "world!"

  assert a & b == cstring "hello world!"
  assert a[0] == 'h'
  assert (a & b)[2 .. 10] == cstring "llo world"

  assert "hello world!"[2 .. 10] == cstring "llo world"

  assert cstring("Hi There!").toLowerAscii() == cstring "hi there!"
  assert cstring("Hi There!").toUpperAscii() == cstring "HI THERE!"

  assert split(cstring ";;this;is;an;;example;;;", ";") ==
    @[cstring"", "", "this", "is", "an", "", "example", "", "", ""]

  assert cstring("hi there").find(cstring "there") == 3
  assert cstring("hi there").contains(cstring "there") == true
  assert cstring("hi there").contains(cstring "other") == false
  assert cstring("there") in cstring("hi there")

  assert cstring("hi there").startsWith(cstring("hi"))
  assert cstring("hi there").endsWith(cstring("there"))

  assert cstring("hi there").startsWith(cstring(""))
  assert cstring("hi there").endsWith(cstring(""))

  assert cstring("hi there").replace(cstring("hi"), cstring("bye")) ==
    cstring("bye there")

  assert cstring("  hi there     ").strip() == "hi there"

  assert cstring("+ foo +").repeat(3) == cstring "+ foo ++ foo ++ foo +"

  assert cstring("123.44").parseFloatJS() == 123.44
  assert cstring("not a float").parseFloatJS().classify == fcNaN
