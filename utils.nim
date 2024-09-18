import std/[unicode, uri, strformat, os, strutils, options, json, jsonutils, sugar, net]
import chronos, chronicles
import "$nim/compiler/pathutils"
import json_rpc/private/jrpc_sys

type
  FingerTable = seq[tuple[u16pos, offset: int]]

  UriParseError* = object of Defect
    uri: string

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

proc utf16to8*(fingerTable: FingerTable, utf16pos: int): int =
  result = utf16pos
  for finger in fingerTable:
    if finger.u16pos < utf16pos:
      result += finger.offset
    else:
      break

when isMainModule:
  import termstyle
  var x = "heållo☀☀wor𐐀𐐀☀ld heållo☀wor𐐀ld heållo☀wor𐐀ld"
  var fingerTable = populateUTFMapping(x)

  var corrected = utf16to8(fingerTable, 5)
  for y in x:
    if corrected == 0:
      echo "-"
    if ord(y) > 125:
      echo ord(y).red
    else:
      echo ord(y)
    corrected -= 1

  echo "utf16\tchar\tutf8\tchar\tchk"
  var pos = 0
  for c in x.runes:
    stdout.write pos
    stdout.write "\t"
    stdout.write c
    stdout.write "\t"
    var corrected = utf16to8(fingerTable, pos)
    stdout.write corrected
    stdout.write "\t"
    stdout.write x.runeAt(corrected)
    if c.int32 == x.runeAt(corrected).int32:
      stdout.write "\tOK".green
    else:
      stdout.write "\tERR".red
    stdout.write "\n"
    if c.int >= 0x10000:
      pos += 2
    else:
      pos += 1

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

proc writeStackTrace*(ex = getCurrentException()) = 
  try:
    stderr.write "An exception occured \n"
    stderr.write ex.msg & "\n"
    stderr.write ex.getStackTrace()
  except IOError:
    discard

proc traceAsyncErrors*(fut: Future) =
  fut.addCallback do(data: pointer):
    if not fut.error.isNil:
      catchOrQuit fut.error[]

iterator groupBy*[T, U](
    s: openArray[T], f: proc(a: T): U {.gcsafe, raises: [].}
): tuple[k: U, v: seq[T]] =
  var t = initTable[U, seq[T]]()
  for x in s:
    let fx = f(x)
    t.mGetOrPut(fx, @[]).add(x)
  for x in t.pairs:
    yield x

#Compatibility layer with asyncdispatch
proc callSoon*(cb: proc() {.gcsafe.}) {.gcsafe.} =
  proc cbWrapper() {.gcsafe.} =
    try:
      {.cast(raises: []).}:
        cb()
    except CatchableError:
      discard #TODO handle  

  callSoon do(data: pointer) {.gcsafe.}:
    cbWrapper()

proc addCallback*(
    future: FutureBase, cb: proc() {.closure, gcsafe, raises: [].}
) {.deprecated: "Replace with built-in chronos mechanism".} =
  ## Adds the callbacks proc to be called when the future completes.
  ##
  ## If future has already completed then `cb` will be called immediately.
  assert cb != nil
  if future.finished:
    callSoon do(data: pointer) {.gcsafe.}:
      cb()
  else:
    future.addCallback do(data: pointer) {.gcsafe.}:
      cb()

proc addCallbackNoEffects[T](
    future: Future[T], cb: proc(future: Future[T]) {.closure, gcsafe, raises: [].}
) =
  ## Adds the callbacks proc to be called when the future completes.
  ##
  ## If future has already completed then `cb` will be called immediately.
  future.addCallback(
    proc() =
      cb(future)
  )

proc addCallback*[T](
    future: Future[T], cb: proc(future: Future[T]) {.closure, gcsafe.}
) {.deprecated.} =
  ## Adds the callbacks proc to be called when the future completes.
  ##
  ## If future has already completed then `cb` will be called immediately.
  proc cbWrapper(fut: Future[T]) {.closure, gcsafe, raises: [].} =
    try:
      {.cast(raises: []).}:
        cb(fut)
    except CatchableError as exc:
      future.fail((ref CatchableError)(msg: exc.msg))

  future.addCallbackNoEffects(
    proc(fut: Future[T]) {.closure, gcsafe, raises: [].} =
      cbWrapper(future)
  )

proc isRelTo*(path, base: string): bool {.raises: [].} =
  ### isRelativeTo version that do not throws
  try:
    isRelativeTo(path, base)
  except Exception:
    false

proc tryRelativeTo*(path, base: string): Option[string] =
  try:
    some relativeTo(AbsoluteFile(path), base.AbsoluteDir).string
  except Exception:
    none(string)

proc get*[T](params: RequestParamsRx, key: string): T =
  if params.kind == rpNamed:
    for np in params.named:
      if np.name == key:
        return np.value.string.parseJson.to(T)
  raise newException(KeyError, "Key not found")

proc to*(params: RequestParamsRx, T: typedesc): T =
  let value = $params.toJson()
  parseJson(value).to(T)

proc head*[T](xs: seq[T]): Option[T] = 
  if xs.len > 0: some(xs[0])
  else: none(T)

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
  
proc ensureStorageDir*: string =
  result = getTempDir() / "nimlangserver"
  discard existsOrCreateDir(result)

proc either*[T](fut1, fut2: Future[T]): Future[T] {.async.} =
  let res =  await race(fut1, fut2)
  if fut1.finished:
    result = fut1.read
    cancelSoon fut2
  else:
    result = fut2.read
    cancelSoon fut1
  
proc map*[T, U](f: Future[T], fn: proc(t:T): U {.raises:[], gcsafe.}): Future[U] {.async.} =
  fn(await f)

proc map*[U](f: Future[void], fn: proc(): U {.raises:[], gcsafe.}): Future[U] {.async.} =
  await f
  fn()

proc withTimeout*[T](fut: Future[T], timeout: int = 500): Future[Option[T]] {.async.} = 
  #Returns None when the timeout is reached and cancels the fut. Otherwise returns the Fut
  let timeoutFut = sleepAsync(timeout).map(() => none(T))
  let optFut = fut.map((r: T) => some r)
  await either(optFut, timeoutFut)

proc getNextFreePort*(): Port= 
  let s = newSocket()
  s.bindAddr(Port(0), "localhost")
  let (_, port) = s.getLocalAddr
  s.close()
  port
  