mode = ScriptMode.Verbose

packageName = "nimtortoise"
version = "0.1.1"
author = "David Pocknee building on the work of the core Nim team"
description = "Fork and rewrite of the nim language server for IDEs"
license = "MIT"
srcDir = "src"
bin = @["nimtortoise"]
binDir = "bin"
skipDirs = @["tests"]

requires "nim >= 2.0.8",
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
  exec "nimble doc --outdir:docs/apidocs --project --index:on --git.url:https://github.com/nim-lang/langserver--git.commit:master --git.devel:master nimtortoise.nim"

task docs, "Generate docs":
  exec "nimble book"
  exec "nimble apidocs"
