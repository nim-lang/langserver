import std/[os, osproc, strutils, options]
import chronicles

import ../langserver/configuration_types

proc getNimVersion*(nimDir: string): string =
  let cmd =
    if nimDir == "":
      "nim --version"
    else:
      nimDir / "nim --version"
  let info = execProcess(cmd)
  const NimCompilerVersion = "Nim Compiler Version "
  for line in info.splitLines:
    if line.startsWith(NimCompilerVersion):
      return line

proc getNimPath*(conf: NlsConfig): Option[string] =
  if conf.nimSuggestPath.isSome and conf.nimsuggestPath.get().fileExists():
    some(conf.nimSuggestPath.get.parentDir / "nim")
  else:
    let path = findExe "nim"
    if path != "":
      some(path)
    else:
      warn "Failed to find nim path"
      none(string)
