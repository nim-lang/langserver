mode = ScriptMode.Verbose

packageName = "nimlangserver"
version = "1.5.2"
author = "The core Nim team"
description = "Nim language server for IDEs"
license = "MIT"
bin = @["nimlangserver"]
skipDirs = @["tests"]

requires "nim == 2.0.8",
  "chronos > 4", "json_rpc#head", "with", "chronicles", "serialization",
  "json_serialization", "stew"

--path:
  "."

task test, "run tests":
  --silent
  --run
  setCommand "c", "tests/all.nim"
