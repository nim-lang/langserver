import ../[utils, ls, lstransports]
import ../protocol/types
import std/[options, os, strutils, unicode, streams]
import chronos
import unittest2

suite "UTF-16 position mapping":
  test "an ASCII only line needs no correction":
    let table = createUTFMapping("proc helloProc() = discard")
    check table.len == 0
    check table.utf16to8(10) == 10
    check table.utf8to16(10) == 10

  test "utf16Len counts UTF-16 units, not bytes or runes":
    check "abc".utf16Len == 3
    check "안녕".utf16Len == 2
    check "안녕".len == 6
    check "𐐀".utf16Len == 2
    check "𐐀".len == 4

  test "a three byte rune shifts later UTF-8 offsets by two per rune":
    let line = "proc a안녕() = discard"
    let table = createUTFMapping(line)
    check table.len == 2
    check table.utf16to8(6) == 6
    check table.utf16to8(7) == 9
    check table.utf16to8(8) == 12

  test "utf8to16 is the inverse of utf16to8 across a mixed line":
    let line = "let a안녕bcd = 0"
    let table = createUTFMapping(line)
    for utf16pos in 0 .. line.utf16Len:
      check table.utf8to16(table.utf16to8(utf16pos)) == utf16pos

  test "a rune outside the BMP takes two UTF-16 units":
    let table = createUTFMapping("x𐐀y")
    check table.len == 1
    check table.utf16to8(3) == 5

suite "uri and path conversion":
  test "pathToUri and uriToPath round trip an absolute path":
    let path = getCurrentDir() / "tests" / "projects" / "hw" / "hw.nim"
    check path.pathToUri.uriToPath == path

  test "pathToUri keeps the path separators unescaped":
    let uri = (getCurrentDir() / "project" / "file.nim").pathToUri
    check uri.startsWith("file:///")
    check "/project/file.nim" in uri

  test "pathToUri escapes characters that are not URI safe":
    let path = getCurrentDir() / "a b" / "c#d.nim"
    let uri = path.pathToUri
    check "%20" in uri
    check "%23" in uri
    check uri.uriToPath == path

  test "a non ascii path survives the round trip":
    let path = getCurrentDir() / "프로젝트" / "hw.nim"
    check path.pathToUri.uriToPath == path

  test "uriToPath rejects a scheme other than file":
    expect UriParseError:
      discard uriToPath("http://example.com/hw.nim")

  test "uriToPath rejects a uri with a hostname":
    expect UriParseError:
      discard uriToPath("file://somehost/hw.nim")

suite "path and seq helpers":
  test "isRelTo reports containment without raising":
    check isRelTo("/a/b/c.nim", "/a/b")
    check not isRelTo("/a/b/c.nim", "/x/y")

  test "isRelTo returns false instead of raising on a malformed path":
    check not isRelTo("", "")

  test "tryRelativeTo returns the relative path when there is one":
    check tryRelativeTo("/a/b/c.nim", "/a/b") == some("c.nim")

  test "head returns the first element or none":
    check @[1, 2, 3].head == some(1)
    check newSeq[int]().head == none(int)

suite "async helpers":
  test "either completes with whichever future finishes first":
    proc slow(): Future[int] {.async.} =
      await sleepAsync(2000)
      1

    proc fast(): Future[int] {.async.} =
      await sleepAsync(10)
      2

    check (waitFor either(slow(), fast())) == 2

  test "withTimeout yields none when the future is too slow":
    proc slow(): Future[int] {.async.} =
      await sleepAsync(2000)
      1

    check (waitFor utils.withTimeout(slow(), 50)).isNone

  test "withTimeout yields the value when the future is fast enough":
    proc fast(): Future[int] {.async.} =
      await sleepAsync(10)
      7

    check (waitFor utils.withTimeout(fast(), 500)) == some(7)

  test "getNextFreePort returns a usable port each time":
    let first = getNextFreePort()
    let second = getNextFreePort()
    check first != Port(0)
    check second != Port(0)

suite "LSP message framing":
  test "wrapContentWithContentLength writes the header the LSP spec asks for":
    let framed = wrapContentWithContentLength("""{"id":1}""")
    check framed == CONTENT_LENGTH & "9" & CRLF & CRLF & """{"id":1}""" & "\n"

  test "the declared length counts bytes, not runes":
    let content = """{"m":"안녕"}"""
    let framed = wrapContentWithContentLength(content)
    let declared = framed.split(CRLF)[0].replace(CONTENT_LENGTH, "").parseInt
    check declared == content.len + 1
    check content.len > content.runeLen

  test "a framed message survives a write and read round trip":
    let
      path = getTempDir() / "nlstest_framing.txt"
      content = """{"jsonrpc":"2.0","id":7,"method":"shutdown"}"""
    writeFile(path, wrapContentWithContentLength(content))
    defer:
      removeFile(path)

    let stream = newFileStream(path, fmRead)
    defer:
      stream.close()
    check stream.processContentLength() == content & "\n"

  test "a message with multi byte characters round trips byte for byte":
    let
      path = getTempDir() / "nlstest_framing_utf8.txt"
      content = """{"jsonrpc":"2.0","params":{"text":"proc a안녕() = discard"}}"""
    writeFile(path, wrapContentWithContentLength(content))
    defer:
      removeFile(path)

    let stream = newFileStream(path, fmRead)
    defer:
      stream.close()
    check stream.processContentLength() == content & "\n"

  test "a header that is not Content-Length is handed back unparsed":
    let path = getTempDir() / "nlstest_framing_bad.txt"
    writeFile(path, "Content-Type: application/json" & CRLF & CRLF & "{}")
    defer:
      removeFile(path)

    let stream = newFileStream(path, fmRead)
    defer:
      stream.close()
    check stream.processContentLength() == "Content-Type: application/json"
