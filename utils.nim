import unicode, uri, strformat, os, strutils, faststreams/async_backend, chronicles, tables

type
  FingerTable = seq[tuple[u16pos, offset: int]]

  UriParseError* = object of Defect
    uri: string

proc createUTFMapping*(line: string): FingerTable =
  var pos = 0
  for rune in line.runes:
    #echo pos
    #echo rune.int32
    case rune.int32:
      of 0x0000..0x007F:
        # One UTF-16 unit, one UTF-8 unit
        pos += 1
      of 0x0080..0x07FF:
        # One UTF-16 unit, two UTF-8 units
        result.add (u16pos: pos, offset: 1)
        pos += 1
      of 0x0800..0xFFFF:
        # One UTF-16 unit, three UTF-8 units
        result.add (u16pos: pos, offset: 2)
        pos += 1
      of 0x10000..0x10FFFF:
        # Two UTF-16 units, four UTF-8 units
        result.add (u16pos: pos, offset: 2)
        pos += 2
      else: discard

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
    var e = newException(UriParseError,
      "Invalid scheme: {parsed.scheme}, only \"file\" is supported".fmt)
    e.uri = uri
    raise e
  if parsed.hostname != "":
    var e = newException(UriParseError,
      "Invalid hostname: {parsed.hostname}, only empty hostname is supported".fmt)
    e.uri = uri
    raise e
  return normalizedPath(
    when defined(windows):
      parsed.path[1..^1]
    else:
      parsed.path).decodeUrl

proc pathToUri*(path: string): string =
  # This is a modified copy of encodeUrl in the uri module. This doesn't encode
  # the / character, meaning a full file path can be passed in without breaking
  # it.
  result = "file://" & newStringOfCap(path.len + path.len shr 2) # assume 12% non-alnum-chars
  for c in path:
    case c
    # https://tools.ietf.org/html/rfc3986#section-2.3
    of 'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~', '/': add(result, c)
    else:
      add(result, '%')
      add(result, toHex(ord(c), 2))

proc catchOrQuit*(error: Exception) =
  if error of CatchableError:
    trace "Async operation ended with a recoverable error", err = error.msg
  else:
    fatal "Fatal exception reached", err = error.msg, stackTrace = getStackTrace()
    quit 1

proc traceAsyncErrors*(fut: Future) =
  fut.addCallback do ():
    if not fut.error.isNil:
      catchOrQuit fut.error[]

iterator groupBy*[T, U](s: openArray[T], f: proc(a: T): U {.gcsafe.}): tuple[k: U, v: seq[T]] =
  var t = initTable[U, seq[T]]()
  for x in s:
    let fx = f(x)
    t.mGetOrPut(fx, @[]).add(x)
  for x in t.pairs:
    yield x
