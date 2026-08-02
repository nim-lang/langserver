import std/[strutils]

proc getVersionFromNimble(): string =
  #We should static run nimble dump instead
  const content = staticRead("../../quicknimlsp.nimble")
  for v in content.splitLines:
    if v.startsWith("version"):
      return v.split("=")[^1].strip(chars = {' ', '"'})
  return "unknown"

const
  RESTART_COMMAND* = "quicknimlsp.restart"
  RECOMPILE_COMMAND* = "quicknimlsp.recompile"
  CHECK_PROJECT_COMMAND* = "quicknimlsp.checkProject"
  FILE_CHECK_DELAY* = 1000
  LSPVersion* = getVersionFromNimble()
  CRLF* = "\r\n"
  CONTENT_LENGTH* = "Content-Length: "
  USE_NIM_CHECK_BY_DEFAULT* = false
  NIM_EXPAND_ARC_BY_DEFAULT* = false
  NIM_EXPAND_MACRO_BY_DEFAULT* = false
  NIM_MAX_NS_PROCESSES* = 1

const 
  CONFIG_WAIT_TIMEOUT_MS* = 30_000
  CONFIG_WAIT_POLL_MS* = 50
