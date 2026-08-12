import std/[strutils]

proc getVersionFromNimble(): string =
  #We should static run nimble dump instead
  const content = staticRead("../../nimtortoise.nimble")
  for v in content.splitLines:
    if v.startsWith("version"):
      return v.split("=")[^1].strip(chars = {' ', '"'})
  return "unknown"

const
  LSPVersion* = getVersionFromNimble()
  CRLF* = "\r\n"

const
  CONFIG_WAIT_TIMEOUT_MS* = 30_000
  CONFIG_WAIT_POLL_MS* = 50
  
  # FILE_CHECK_DELAY* = 1000
  # NIM_EXPAND_ARC_BY_DEFAULT* = false
  # NIM_EXPAND_MACRO_BY_DEFAULT* = false
  # NIM_MAX_NS_PROCESSES* = 2
  
  # DEFAULT_IDLE_TIMEOUT* = 10 ## idle timeout in minutes
  # MAX_CRASH_RETRIES* = 3 ## auto-restart attempts before giving up on a crashed slot
