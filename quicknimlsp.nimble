mode = ScriptMode.Verbose

packageName = "quicknimlsp"
version = "1.15.0"
author = "David Pocknee and The core Nim team"
description = "Alternative Nim language server for IDEs"
license = "MIT"
bin = @["quicknimlsp"]
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
  exec "nimble doc --outdir:docs/apidocs --project --index:on --git.url:https://github.com/nim-lang/langserver--git.commit:master --git.devel:master quicknimlsp.nim"

task docs, "Generate docs":
  exec "nimble book"
  exec "nimble apidocs"
