import std/[os]
import chronicles

const NIM_SCRIPT_API_TEMPLATE* = staticRead("./nimscriptapi.nim")

proc getNimScriptAPITemplatePath*(): string =
  result = getCacheDir("nimtortoise")
  createDir(result)
  result = result / "nimscriptapi.nim"

  once:
    if not result.fileExists or result.readFile != NIM_SCRIPT_API_TEMPLATE:
      writeFile(result, NIM_SCRIPT_API_TEMPLATE)
  debug "NimScriptApiPath", path = result

  #We add this file to nimsuggest and `nim check` to support nimble files
