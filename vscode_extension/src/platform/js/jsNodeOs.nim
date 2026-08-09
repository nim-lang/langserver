import std/jsffi

type
  OsModule* = ref OsModuleObj
  OsModuleObj {.importc.} = object of JsRoot
    eol* {.importcpp: "EOL".}: cstring

proc tmpdir*(os: OsModule): cstring {.importcpp.}

proc homedir*(os: OsModule): cstring {.importcpp.}

var nodeOs* = require("os").to(OsModule)
