{.push raises: [], gcsafe.}

import
  std/[strutils],
  regex,
  chronos,
  chronos/asyncproc,
  stew/[byteutils],
  chronicles,
  ./utils

export RegexError

type
  CheckStacktrace* = object
    file*: string
    line*: int
    column*: int
    msg*: string

  CheckResult* = object
    file*: string
    line*: int
    column*: int
    msg*: string
    severity*: string
    stacktrace*: seq[CheckStacktrace]

proc parseCheckResults*(lines: seq[string]): seq[CheckResult] =
  ## `file(line, col) Severity: message` starts a diagnostic, and the lines after it that
  ## start nothing else go on with its message (a type mismatch's candidates). A
  ## `file(line, col) text` line with no severity (an instantiation's "from here") comes
  ## before the diagnostic it belongs to: it goes on the next one. nim's own messages,
  ## `Hint: ...` or `Warning: ...` with no place (the config files it read, the build's
  ## summary), belong to none; a placeless `Error: ...` goes on the last one, as before.
  result = @[]
  var
    context: seq[string] # lines for the next diagnostic
    open = false # whether a line that starts nothing goes on result[^1]
    m: RegexMatch2

  let dotsPattern = re2"^\.+$"
  let errorPattern = re2"^([^(]+)\((\d+),\s*(\d+)\)\s*(\w+):\s*(.*)$"
  let contextPattern = re2"^[^(]+\(\d+,\s*\d+\)\s+.*$"
  let ownPattern = re2"^(Hint|Warning|Error):\s*(.*)$"

  proc extend(msg: var string, line: string) =
    if msg.len < 2048:
      msg &= "\n" & line

  for line in lines:
    let line = line.strip()

    if line == "" or line.match(dotsPattern):
      continue

    if find(line, errorPattern, m):
      try:
        var r = CheckResult(
          file: line[m.captures[0]],
          line: parseInt(line[m.captures[1]]),
          column: parseInt(line[m.captures[2]]),
          severity: line[m.captures[3]],
          msg: line[m.captures[4]],
          stacktrace: @[],
        )
        for c in context:
          r.msg.extend c
        context.setLen 0
        result.add r
        open = true
      except ValueError as e:
        error "Error processing line", line = line, msg = e.msg
        open = false
    elif line.match(contextPattern):
      context.add line
      open = false
    elif find(line, ownPattern, m):
      if line[m.captures[0]] == "Error" and result.len > 0:
        result[^1].msg.extend line
      open = false
    elif open:
      result[^1].msg.extend line

proc nimCheck*(
    filePath: string, nimPath: string
): Future[seq[CheckResult]] {.
    async:
      (raises: [CancelledError, AsyncProcessError, AsyncStreamError, OSError, IOError])
.} =
  debug "nimCheck", filePath = filePath, nimPath = nimPath
  let isNimble = filePath.endsWith(".nimble")
  let isNimScript = filePath.endsWith(".nims") or isNimble
  var extraArgs = newSeq[string]()
  if isNimScript:
    extraArgs.add("--import: system/nimscript")
  if isNimble:
    extraArgs.add("--include: " & getNimScriptAPITemplatePath())
  let process = await startProcess(
    nimPath,
    arguments = @["check", "--listFullPaths"] & extraArgs & @[filePath],
    options = {UsePath},
    stderrHandle = AsyncProcess.Pipe,
    stdoutHandle = AsyncProcess.Pipe,
  )
  try:
    # nim writes its errors, warnings and hints to stderr, whatever it exits with: read
    # it (and stdout) while nim runs, since a pipe that fills up (64 KiB) would block nim
    # and it would never exit
    let
      errOutput = process.stderrStream.read()
      stdOutput = process.stdoutStream.read()
    discard await process.waitForExit(15.seconds)
    let output =
      string.fromBytes(errOutput.await) & "\n" & string.fromBytes(stdOutput.await)

    let lines = output.splitLines()
    parseCheckResults(lines)
  finally:
    await shutdownChildProcess(process)
