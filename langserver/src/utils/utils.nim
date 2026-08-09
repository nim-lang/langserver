import std/[unicode, uri, strformat, os, strutils, options, json, jsonutils, net, hashes]
# import with
import chronos, chronicles
import "$nim/compiler/pathutils"
import json_rpc/private/jrpc_sys
import macros
import ../protocol/types as protocolTypes
export FileUri, FilePath

type
  UriParseError* = object of Defect
    uri: FileUri

  FingerTable = seq[tuple[u16pos, offset: int]]

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

func toFileUri*(x: string): FileUri = FileUri(x)
func toFilePath*(x: string): FilePath = FilePath(x)

proc uriToPath*(uri: FileUri): FilePath =
  ## Convert an RFC 8089 file URI to a native, platform-specific, absolute path.
  #let startIdx = when defined(windows): 8 else: 7
  #normalizedPath(uri[startIdx..^1])
  let uriAsString = $(uri)
  let parsed = parseUri(uriAsString)
  if parsed.scheme != "file":
    var e = newException(
      UriParseError,
      fmt"""Invalid scheme in uri "{uriAsString}": {parsed.scheme}, only "file" is supported"""
    )
    e.uri = FileUri(uriAsString)
    raise e
  if parsed.hostname != "":
    var e = newException(
      UriParseError,
      fmt"""Invalid hostname in uri "{uriAsString}": {parsed.hostname}, only empty hostname is supported""",
    )
    e.uri = FileUri(uriAsString)
    raise e
  return FilePath(normalizedPath(
    when defined(windows):
      parsed.path[1 ..^ 1]
    else:
      parsed.path
  ).decodeUrl())



proc pathToUri*(path: FilePath): FileUri =
  # This is a modified copy of encodeUrl in the uri module. This doesn't encode
  # the / character, meaning a full file path can be passed in without breaking
  # it.
  let pathAsString = $(path)
  var output = "file://" & newStringOfCap(pathAsString.len + pathAsString.len shr 2)
    # assume 12% non-alnum-chars
  when defined(windows):
    output.add('/')
  for c in pathAsString:
    case c
    # https://tools.ietf.org/html/rfc3986#section-2.3
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '.', '_', '~', '/':
      output.add(c)
    of '\\':
      when defined(windows):
        output.add('/')
      else:
        output.add('%')
        output.add(toHex(ord(c), 2))
    else:
      output.add('%')
      output.add(toHex(ord(c), 2))
  
  return FileUri(output)

iterator groupBy*[T, U](
    s: openArray[T], f: proc(a: T): U {.gcsafe, raises: [].}
): tuple[k: U, v: seq[T]] =
  var t = initTable[U, seq[T]]()
  for x in s:
    let fx = f(x)
    t.mGetOrPut(fx, @[]).add(x)
  for x in t.pairs:
    yield x

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
  let value =
    case params.kind
    of rpNamed:
      $params.toJson()

    # Normally, this shouldn't happen as neither LSP nor MCP
    # use positional params.
    # But Copilot CLI would send no params to tools/list
    # method which are parsed as an empty array of positional params.
    # Since you can't parse an array into a json object,
    # we simply ignore any positional params and parse an empty
    # object instead.
    of rpPositional:
      doAssert len(params.positional) == 0
      $newJObject()

  parseJson(value).to(T)

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

proc ensureStorageDir*(): string =
  result = getTempDir() / "nimtortoise"
  discard existsOrCreateDir(result)

proc either*[T](fut1, fut2: Future[T]): Future[T] {.async.} =
  let res = await race(fut1, fut2)
  if fut1.finished:
    result = fut1.read
    cancelSoon fut2
  else:
    result = fut2.read
    cancelSoon fut1

proc map*[T, U](
    f: Future[T], fn: proc(t: T): U {.raises: [], gcsafe.}
): Future[U] {.async.} =
  fn(await f)

proc map*[U](
    f: Future[void], fn: proc(): U {.raises: [], gcsafe.}
): Future[U] {.async.} =
  await f
  fn()

func isWord*(str: string): bool =
  var str = str.toLower()
  for c in str:
    if c.int notin {48 .. 57, 97 .. 122}: # Allow 0-9 and a-z
      return false
  return true

macro getField*(obj: object, fld: string): untyped =
  result = newDotExpr(obj, newIdentNode(fld.strVal))

macro `%*`*(t: untyped, inputStream: untyped): untyped =
  result =
    newCall(bindSym("to", brOpen), newCall(bindSym("%*", brOpen), inputStream), t)
  
when isMainModule:
  import termstyle
  var x = "heållo☀☀wor𐐀𐐀☀ld heållo☀wor𐐀ld heållo☀wor𐐀ld"
  var fingerTable = createUTFMapping(x)

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

