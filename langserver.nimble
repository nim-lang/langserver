mode = ScriptMode.Verbose

packageName   = "langserver"
version       = "0.0.1"
author        = "The core Nim team"
description   = "Nim language server for IDEs"
license       = "MIT"
bin           = @["nls"]
skipDirs      = @["tests"]

requires "nim >= 0.17.0", "asynctools >= 0.1.0", "json_rpc", "jsonschema",
  "with", "itertools", "chronicles"

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
  --define:"chronicles_timestamps=RfcTime"
  --define:"debugLogging"

task test, "run tests":
  configForTests()
  setCommand "c", "tests/all.nim"
