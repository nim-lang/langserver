import chronos, chronos/asyncproc, os, strutils, strformat, chronicles, suggestapi

type TrackMode* = enum
  tmDef = "def"
  tmUsages = "usages"
  tmDefUsages = "defusages"

proc parseTrackOutput(raw: string): seq[Suggest] =
  for line in raw.splitLines:
    if line.len == 0 or line.startsWith("Hint:") or
        not (line.startsWith("def\t") or line.startsWith("use\t")):
      continue
    let tokens = line.split('\t')
    if tokens.len < 8:
      continue
    result.add Suggest(
      section: parseEnum[IdeCmd]("ide" & capitalizeAscii(tokens[0])),
      symKind: tokens[1],
      qualifiedPath: parseQualifiedPath(tokens[2]),
      forth: tokens[3],
      filePath: tokens[4],
      line: parseInt(tokens[5]),
      column: parseInt(tokens[6]),
    )

proc track*(
    projectFile, file: string, line, col: int, mode: TrackMode,
    nimPath = "nim", timeout = REQUEST_TIMEOUT
): Future[seq[Suggest]] {.async.} =
  let
    workingDir = projectFile.parentDir()
    arg = fmt "--{$mode}:{file},{line},{col}"

  debug "nim track", projectFile = projectFile, arg = arg

  let process = await startProcess(
    nimPath,
    workingDir = workingDir,
    arguments = @["track", projectFile, arg],
    options = {UsePath},
    stdoutHandle = AsyncProcess.Pipe,
    stderrHandle = AsyncProcess.Pipe,
  )

  try:
    let exitCode = await process.waitForExit(timeout.milliseconds)
    let stdoutBytes = process.stdoutStream.read().await
    var stderrStr = ""
    try:
      stderrStr = process.stderrStream.read().await.toString
    except CatchableError:
      discard
    if "invalid command: track" in stderrStr:
      warn "nim track not supported (requires nim >= 2.3.1)", nimPath = nimPath
      return @[]
    if exitCode != 0:
      debug "nim track exit", exitCode = exitCode
    result = parseTrackOutput(stdoutBytes.toString)
  except CatchableError as e:
    debug "nim track exception", error = e.msg, name = e.name
    result = @[]
