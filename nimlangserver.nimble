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
         "chronicles"

--path:"."

proc configForTests() =
  --hints: off
  --debuginfo
  --run
  --threads:on
  --silent
  --define:"debugLogging=on"
  --define:"chronicles_disable_thread_id"
  --define:"async_backend=asyncdispatch"
  --define:"chronicles_timestamps=None"
  --define:"debugLogging"

task test, "run tests":
  configForTests()
  setCommand "c", "tests/all.nim"
