import std/distros

mode = ScriptMode.Verbose

packageName   = "nimlangserver"
version       = "1.3.1"
author        = "The core Nim team"
description   = "Nim language server for IDEs"
license       = "MIT"
bin           = @["nimlangserver"]
skipDirs      = @["tests"]

requires "nim >= 2.0.0",
         "https://github.com/nickysn/asynctools#fixes_for_nimlangserver",
         "https://github.com/yyoncho/nim-json-rpc#notif-changes",
         "with",
         "chronicles",
         "serialization",
         "json_serialization"


--path:"."

task test, "run tests":
  --silent
  --run
  setCommand "c", "tests/all.nim"

task setup, "Setup":
  if detectOs(Ubuntu):
    foreignDep "libpcre3"
    echo ""
    echo "You may need to install following dependencies:"
    echo ""
    echoForeignDeps()
    echo ""

before install:
  setupTask()
