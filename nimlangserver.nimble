mode = ScriptMode.Verbose

packageName = "nimlangserver"
version = "1.14.0"
author = "The core Nim team"
description = "Nim language server for IDEs"
license = "MIT"
bin = @["nimlangserver"]
skipDirs = @["tests"]

requires "nim >= 2.2.12",
  "chronos >= 4.2.2 & < 4.3.0",
  "https://github.com/nitely/nim-json-rpc.git#947cdf0d3adc759d417764776d8b042a5c85168d",
  "with >= 0.5.0", "chronicles >= 0.12.2",
  "serialization >= 0.5.2", "json_serialization >= 0.4.4", "stew >= 0.5.0",
  "regex >= 0.26.3", "unittest2 >= 0.2.5"

--path:
  "."

task test, "run tests":
  exec "nim c --styleCheck:usages --styleCheck:error -r tests/all.nim"

task docs, "Generate docs":
  exec "mdbook build book -d ../docs"
