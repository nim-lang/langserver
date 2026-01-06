mode = ScriptMode.Verbose

packageName = "nimlangserver"
version = "1.12.0"
author = "The core Nim team"
description = "Nim language server for IDEs"
license = "MIT"
bin = @["nimlangserver"]
skipDirs = @["tests"]

requires "nim == 2.0.8",
  "chronos >= 4.0.4", "json_rpc >= 0.5.0", "with", "chronicles", "serialization",
  "json_serialization", "stew", "regex","unittest2 == 0.2.5"

--path:
  "."

task test, "run tests":
  --silent
  --run
  setCommand "c", "tests/all.nim"
