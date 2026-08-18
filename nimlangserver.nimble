mode = ScriptMode.Verbose

packageName = "nimlangserver"
version = "1.14.0"
author = "The core Nim team"
description = "Nim language server for IDEs"
license = "MIT"
bin = @["nimlangserver"]
skipDirs = @["tests"]

requires "nim >= 2.2.10",
  "chronos >= 4.2.2", "json_rpc >= 0.6.0", "with >= 0.5.0", "chronicles >= 0.12.2",
  "serialization >= 0.5.2", "json_serialization >= 0.4.4", "stew >= 0.5.0",
  "regex >= 0.26.3", "unittest2 >= 0.2.5"

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
