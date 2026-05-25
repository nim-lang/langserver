mode = ScriptMode.Verbose

packageName = "nimlangserver"
version = "1.14.0"
author = "The core Nim team"
description = "Nim language server for IDEs"
license = "MIT"
bin = @["nimlangserver"]
skipDirs = @["tests"]

requires "nim == 2.0.8",
  "chronos >= 4.0.4", "json_rpc >= 0.5.0", "with", "chronicles", "serialization",
  "json_serialization", "stew", "regex", "unittest2 >= 0.2.4"

--path:
  "."

task test, "run tests":
  --silent
  --run
  setCommand "c", "tests/all.nim"

task book, "Generate book":
  exec "mdbook build book -d ../docs"

task apidocs, "Generate API docs":
  exec "nimble doc --outdir:docs/apidocs --project --index:on --git.url:https://github.com/nim-lang/langserver--git.commit:master --git.devel:master nimlangserver.nim"

task docs, "Generate docs":
  exec "nimble book"
  exec "nimble apidocs"
