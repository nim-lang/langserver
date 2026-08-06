import chronos, chronicles, chronos/asyncproc
import stew/byteutils
import ../protocol/types

const NIM_SCRIPT_API_TEMPLATE* = staticRead("../templates/nimscriptapi.nim")

proc getNimScriptAPITemplatePath*(): string =
  result = getCacheDir("quicknimlsp")
  createDir(result)
  result = result / "nimscriptapi.nim"

  once:
    if not result.fileExists or result.readFile != NIM_SCRIPT_API_TEMPLATE:
      writeFile(result, NIM_SCRIPT_API_TEMPLATE)
  debug "NimScriptApiPath", path = result

  #We add this file to nimsuggest and `nim check` to support nimble files
