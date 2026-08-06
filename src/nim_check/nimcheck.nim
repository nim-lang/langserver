import std/[strutils]
import regex
import chronos, chronos/asyncproc
import stew/[byteutils]
import chronicles
import ../../langserver/utils

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

proc parseCheckResults(lines: seq[string]): seq[CheckResult] =
  result = @[]
  var
    messageText = ""
    stacktrace: seq[CheckStacktrace]
    lastFile, lastLineStr, lastCharStr: string
    m: RegexMatch2

  let dotsPattern = re2"^\.+$"
  let errorPattern = re2"^([^(]+)\((\d+),\s*(\d+)\)\s*(\w+):\s*(.*)$"

  for line in lines:
    let line = line.strip()

    if line.startsWith("Hint: used config file") or line == "" or line.match(
      dotsPattern
    ):
      continue

    if not find(line, errorPattern, m):
      if messageText.len < 1024:
        messageText &= "\n" & line
    else:
      try:
        let
          file = line[m.captures[0]]
          lineStr = line[m.captures[1]]
          charStr = line[m.captures[2]]
          severity = line[m.captures[3]]
          msg = line[m.captures[4]]

        let
          lineNum = parseInt(lineStr)
          colNum = parseInt(charStr)

        result.add(
          CheckResult(
            file: file,
            line: lineNum,
            column: colNum,
            msg: msg,
            severity: severity,
            stacktrace: @[],
          )
        )
      except Exception as e:
        error "Error processing line", line = line, msg = e.msg
        continue

  if messageText.len > 0 and result.len > 0:
    result[^1].msg &= "\n" & messageText

proc nimCheck*(filePath: string, nimPath: string): Future[seq[CheckResult]] {.async.} =
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
    let res = await process.waitForExit(15.seconds)
    # debug "nimCheck exit", res = res
    var output = ""
    if res == 0:
      #Nim check return 0 if there are no errors but we still need to check for hints and warnings
      output = string.fromBytes(process.stdoutStream.read().await)
    else:
      output = string.fromBytes(process.stderrStream.read().await)

    let lines = output.splitLines()
    parseCheckResults(lines)
  finally:
    await shutdownChildProcess(process)


proc toDiagnosticJson(checkResult: CheckResult): JsonNode =
  let
    textStart = checkResult.msg.find('\'')
    textEnd = checkResult.msg.rfind('\'')
    endColumn =
      if textStart >= 0 and textEnd >= 0 and textEnd > textStart:
        checkResult.column + utf16Len(checkResult.msg[textStart + 1 ..< textEnd])
      else:
        checkResult.column + 1

  let r = range(
    checkResult.line - 1,
    max(0, checkResult.column),
    checkResult.line - 1,
    max(0, endColumn),
  )
  result = %*{
    "uri": pathToUri(checkResult.file),
    "range": %*{
      "start": %*{"line": r.start.line, "character": r.start.character},
      "end": %*{"line": r.`end`.line, "character": r.`end`.character},
    },
    "severity":
      case checkResult.severity
      of "Error": DiagnosticSeverity.Error.int
      of "Hint": DiagnosticSeverity.Hint.int
      of "Warning": DiagnosticSeverity.Warning.int
      else: DiagnosticSeverity.Error.int
    ,
    "message": checkResult.msg,
    "source": "nim",
    "code": "nim check",
  }

