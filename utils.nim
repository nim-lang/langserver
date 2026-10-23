{.push raises: [], gcsafe.}

import
  std/[macros, unicode, uri, strformat, os, strutils, options, json, net, paths],
  chronos,
  chronicles,
  chronos/asyncproc,
  json_rpc/private/jrpc_sys,
  stew/byteutils

type
  FingerTable = seq[tuple[u16pos, offset: int]]

  UriParseError* = object of Defect
    uri: string

const NIM_SCRIPT_API_TEMPLATE* = staticRead("templates/nimscriptapi.nim")
  #We add this file to nimsuggest and `nim check` to support nimble files

proc writeStackTrace*(ex = getCurrentException()) =
  try:
    if ex != nil:
      stderr.write "An exception occured \n"
      stderr.write ex.msg & "\n"
      stderr.write ex.getStackTrace()
    else:
      stderr.write getStackTrace()
  except IOError:
    discard

proc createUTFMapping*(line: string): FingerTable =
  var pos = 0
  for rune in line.runes:
    #echo pos
    #echo rune.int32
    case rune.int32
    of 0x0000 .. 0x007F:
      # One UTF-16 unit, one UTF-8 unit
      pos += 1
    of 0x0080 .. 0x07FF:
      # One UTF-16 unit, two UTF-8 units
      result.add (u16pos: pos, offset: 1)
      pos += 1
    of 0x0800 .. 0xFFFF:
      # One UTF-16 unit, three UTF-8 units
      result.add (u16pos: pos, offset: 2)
      pos += 1
    of 0x10000 .. 0x10FFFF:
      # Two UTF-16 units, four UTF-8 units
      result.add (u16pos: pos, offset: 2)
      pos += 2
    else:
      discard

  #echo fingerTable

proc utf16Len*(utf8Str: string): int =
  result = 0
  for rune in utf8Str.runes:
    case rune.int32
    of 0x0000 .. 0x007F, 0x0080 .. 0x07FF, 0x0800 .. 0xFFFF:
      result += 1
    of 0x10000 .. 0x10FFFF:
      result += 2
    else:
      discard

proc utf16to8*(fingerTable: FingerTable, utf16pos: int): int =
  result = utf16pos
  for finger in fingerTable:
    if finger.u16pos < utf16pos:
      result += finger.offset
    else:
      break

proc utf8to16*(fingerTable: FingerTable, utf8pos: int): int =
  result = utf8pos
  for finger in fingerTable:
    if finger.u16pos < result:
      result -= finger.offset
    else:
      break

proc uriToPath*(uri: string): string =
  ## Convert an RFC 8089 file URI to a native, platform-specific, absolute path.
  #let startIdx = when defined(windows): 8 else: 7
  #normalizedPath(uri[startIdx..^1])
  let parsed = uri.parseUri
  if parsed.scheme != "file":
    var e = newException(
      UriParseError,
      "Invalid scheme in uri \"{uri}\": {parsed.scheme}, only \"file\" is supported".fmt,
    )
    e.uri = uri
    raise e
  if parsed.hostname != "":
    var e = newException(
      UriParseError,
      "Invalid hostname in uri \"{uri}\": {parsed.hostname}, only empty hostname is supported".fmt,
    )
    e.uri = uri
    raise e
  return normalizedPath(
    when defined(windows):
      parsed.path[1 ..^ 1]
    else:
      parsed.path
  ).decodeUrl

proc pathToUri*(path: string): string =
  # This is a modified copy of encodeUrl in the uri module. This doesn't encode
  # the / character, meaning a full file path can be passed in without breaking
  # it.
  result = "file://" & newStringOfCap(path.len + path.len shr 2)
    # assume 12% non-alnum-chars
  when defined(windows):
    add(result, '/')
  for c in path:
    case c
    # https://tools.ietf.org/html/rfc3986#section-2.3
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '.', '_', '~', '/':
      add(result, c)
    of '\\':
      when defined(windows):
        add(result, '/')
      else:
        add(result, '%')
        add(result, toHex(ord(c), 2))
    else:
      add(result, '%')
      add(result, toHex(ord(c), 2))

proc catchOrQuit*(error: Exception) =
  if error of CatchableError:
    trace "Async operation ended with a recoverable error", err = error.msg
  else:
    fatal "Fatal exception reached", err = error.msg, stackTrace = getStackTrace()
    quit 1

proc traceAsyncErrors*(fut: FutureBase) =
  fut.addCallback do(data: pointer):
    if not fut.error.isNil:
      catchOrQuit fut.error[]

iterator groupBy*[T, U](
    s: openArray[T], f: proc(a: T): U {.gcsafe, raises: [].}
): tuple[k: U, v: seq[T]] =
  var t = initTable[U, seq[T]]()
  for x in s:
    let fx = f(x)
    t.mgetOrPut(fx, @[]).add(x)
  for x in t.pairs:
    yield x

proc isRelTo*(path, base: string): bool {.raises: [].} =
  ### isRelativeTo version that do not throws
  try:
    isRelativeTo(path, base)
  except ValueError, OSError:
    debug "isRelTo error", path = path, base = base, err = getCurrentExceptionMsg()
    false

proc tryRelativeTo*(path, base: string): Option[string] =
  try:
    some $relativePath(path, base)
  except ValueError, OSError:
    debug "tryRelativeTo error",
      path = path, base = base, err = getCurrentExceptionMsg()
    none(string)

proc get*[T](
    params: RequestParamsRx, key: string
): T {.raises: [ValueError, IOError, OSError].} =
  if params.kind == rpNamed:
    for np in params.named:
      if np.name == key:
        return np.value.string.parseJson.to(T)
  raise newException(KeyError, "Key not found")

proc head*[T](xs: seq[T]): Option[T] =
  if xs.len > 0:
    some(xs[0])
  else:
    none(T)

proc partial*[A, B, C](
    fn: proc(a: A, b: B): C {.gcsafe, raises: [], nimcall.}, a: A
): proc(b: B): C {.gcsafe, raises: [].} =
  return proc(b: B): C {.gcsafe, raises: [].} =
    return fn(a, b)

proc partial*[A, B](
    fn: proc(a: A, b: B): void {.gcsafe, raises: [], nimcall.}, a: A
): proc(b: B): void {.gcsafe, raises: [].} =
  return proc(b: B): void {.gcsafe, raises: [].} =
    fn(a, b)

proc partial*[A, B, C, D](
    fn: proc(a: A, b: B, c: C): D {.gcsafe, raises: [], nimcall.}, a: A
): proc(b: B, c: C): D {.gcsafe, raises: [].} =
  return proc(b: B, c: C): D {.gcsafe, raises: [].} =
    return fn(a, b, c)

proc partial*[A, B, C, D, E](
    fn: proc(a: A, b: B, c: C, d: D): E {.gcsafe, raises: [], nimcall.}, a: A
): proc(b: B, c: C, d: D): E {.gcsafe, raises: [].} =
  return proc(b: B, c: C, d: D): E {.gcsafe, raises: [].} =
    return fn(a, b, c, d)

proc ensureStorageDir*(): string {.raises: [OSError, IOError].} =
  result = getTempDir() / "nimlangserver"
  discard existsOrCreateDir(result)

proc withTimeout*[T](fut: Future[T]): Future[bool].Raising([CancelledError]) =
  withTimeout(fut, chronos.milliseconds(500))

proc getNextFreePort*(): Port {.raises: [OSError, ValueError].} =
  let s = newSocket()
  s.bindAddr(Port(0), "localhost")
  let (_, port) =
    try:
      s.getLocalAddr()
    except OSError as exc:
      raise exc
    except CatchableError as exc:
      raise newException(OSError, exc.msg)
    except Defect as exc:
      raise exc
    except Exception as exc:
      raiseAssert "Unhandled exception " & exc.msg
  s.close()
  port

func isWord*(str: string): bool =
  var str = str.toLower()
  for c in str:
    if c.int notin {48 .. 57, 97 .. 122}: # Allow 0-9 and a-z
      return false
  return true

proc getNimScriptAPITemplatePath*(): string {.raises: [OSError, IOError].} =
  result = getCacheDir("nimlangserver")
  createDir(result)
  result = result / "nimscriptapi.nim"

  once:
    if not result.fileExists or result.readFile != NIM_SCRIPT_API_TEMPLATE:
      writeFile(result, NIM_SCRIPT_API_TEMPLATE)
  debug "NimScriptApiPath", path = result

# keep this raises free
proc shutdownChildProcess*(p: AsyncProcessRef): Future[void] {.async: (raises: []).} =
  try:
    debug "Shutting down process with pid: ", pid = p.processId()
    let exitCode = await noCancel p.terminateAndWaitForExit(2.seconds)
      # debug "Process terminated with exit code: ", exitCode
  except AsyncProcessError:
    try:
      let forcedExitCode = await noCancel p.killAndWaitForExit(3.seconds)
      debug "Process forcibly killed with exit code: ", exitCode = forcedExitCode
    except AsyncProcessError:
      debug "Could not kill process in time either!"
      writeStackTrace()

macro getField*(obj: object, fld: string): untyped =
  result = newDotExpr(obj, newIdentNode(fld.strVal))

proc readAllOutput*(
    stream: AsyncStreamReader
): Future[string] {.async: (raises: [CancelledError, AsyncStreamError]).} =
  result = ""
  while not stream.atEof:
    let data = await stream.read()
    result.add(string.fromBytes(data))

proc readErrorOutputUntilExit*(
    process: AsyncProcessRef, duration: Duration
): Future[tuple[output: string, code: int]] {.
    async: (raises: [CancelledError, AsyncProcessError, AsyncStreamError])
.} =
  var output = ""
  var res = 0
  while true:
    if not process.stderrStream.atEof:
      let data = await process.stderrStream.read()
      output.add(string.fromBytes(data))

    let hasExited =
      try:
        res = await process.waitForExit(duration)
        true
      except AsyncTimeoutError:
        false

    if hasExited:
      while not process.stderrStream.atEof:
        let data = await process.stderrStream.read()
        output.add(string.fromBytes(data))
      return (output, res)

proc readOutputUntilExit*(
    process: AsyncProcessRef, duration: Duration
): Future[tuple[output: string, error: string, code: int]] {.
    async: (raises: [CancelledError, AsyncProcessError])
.} =
  var output = ""
  var error = ""
  var res = 0
  # debug "Starting read output until exit"

  while true:
    let hasExited =
      try:
        res = await process.waitForExit(duration)
        debug "Process exit check", hasExited = true, res = res
        true
      except AsyncTimeoutError:
        debug "Process still running"
        false

    # Quick non-blocking reads
    try:
      if not process.stdoutStream.atEof:
        # debug "Attempting stdout read"
        let data = await process.stdoutStream.read() #
        if data.len > 0:
          # debug "Got stdout data", len = data.len
          output.add(string.fromBytes(data))
    except AsyncStreamError as e:
      debug "Stdout read error", msg = e.msg

    try:
      if not process.stderrStream.atEof:
        # debug "Attempting stderr read"
        let data = await process.stderrStream.read()
        if data.len > 0:
          # debug "Got stderr data", len = data.len
          error.add(string.fromBytes(data))
    except AsyncStreamError as e:
      debug "Stderr read error", msg = e.msg

    if hasExited:
      # debug "Process has exited, final cleanup", output = output, error = error, code = res
      return (output, error, res)
