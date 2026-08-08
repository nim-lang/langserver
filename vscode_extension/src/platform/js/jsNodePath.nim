import std/jsffi

# TODO - likely entirely replaceable with https://nim-lang.org/docs/os.html

type
  Path* = ref PathObj
  PathObj {.importc.} = object of JsRoot
    sep*: cstring
    delimiter*: cstring
    platform*: cstring # should be an enum like thing

  ParsedPath* = ref object # The root of the path such as '/' or 'c:\'
    root*: cstring
    # The full directory path such as '/home/user/dir' or 'c:\path\dir'
    dir*: cstring
    # The file name including extension (if any) such as 'index.html'
    base*: cstring
    # The file extension (if any) such as '.html'
    ext*: cstring
    # The file name without extension (if any) such as 'index'
    name*: cstring

proc resolve*(p: Path, paths: cstring): cstring {.importcpp, varargs.}
proc join*(p: Path, paths: cstring): cstring {.importcpp, varargs.}
proc dirname*(p: Path, path: cstring): cstring {.importcpp.}
proc basename*(p: Path, path: cstring): cstring {.importcpp.}
proc basename*(p: Path, path: cstring, ext: cstring): cstring {.importcpp.}
proc extname*(p: Path, path: cstring): cstring {.importcpp.}
proc isAbsolute*(p: Path, path: cstring): bool {.importcpp.}
proc parse*(p: Path, str: cstring): ParsedPath {.importcpp.}
proc normalize*(p: Path, str: cstring): cstring {.importcpp.}

var path*: Path = require("path").to(Path)
