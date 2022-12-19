mode = ScriptMode.Verbose

packageName   = "nimlangserver"
version       = "0.1.0"
author        = "The core Nim team"
description   = "Nim language server for IDEs"
license       = "MIT"
bin           = @["nimlangserver"]
skipDirs      = @["tests"]

requires "nim >= 1.0.0",
         "https://github.com/yyoncho/asynctools#non-blocking",
         "https://github.com/yyoncho/nim-json-rpc#notif-changes",
         "with",
         "itertools",
         "chronicles"

--path:"."

task test, "run tests":
  --silent
  setCommand "c", "tests/all.nim"
