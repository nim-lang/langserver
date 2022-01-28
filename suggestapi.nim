import osproc,
  strutils,
  with,
  strformat,
  os,
  asyncnet,
  streams,
  faststreams/async_backend,
  asyncdispatch

# coppied from Nim repo
type
  PrefixMatch* {.pure.} = enum
    None,   ## no prefix detected
    Abbrev  ## prefix is an abbreviation of the symbol
    Substr, ## prefix is a substring of the symbol
    Prefix, ## prefix does match the symbol

  IdeCmd* = enum
    ideNone, ideSug, ideCon, ideDef, ideUse, ideDus, ideChk, ideMod,
    ideHighlight, ideOutline, ideKnown, ideMsg, ideProject

  Suggest* = ref object of RootObj
    section*: IdeCmd
    qualifiedPath*: seq[string]
    name*: ptr string         # not used beyond sorting purposes; name is also
                              # part of 'qualifiedPath'
    filePath*: string
    line*: int                   # Starts at 1
    column*: int                 # Starts at 0
    doc*: string           # Not escaped (yet)
    forth*: string               # type
    quality*: range[0..100]   # matching quality
    isGlobal*: bool # is a global variable
    contextFits*: bool # type/non-type context matches
    prefix*: PrefixMatch
    symkind*: byte
    scope*, localUsages*, globalUsages*: int # more usages is better
    tokenLen*: int
    version*: int

  SuggestApi* = ref object
    process: Process
    port: int
    # socket: AsyncSocket

proc parseSuggest*(line: string): Suggest =
  let tokens = line.split('\t');

  return Suggest(
    filePath: tokens[4],
    line: parseInt(tokens[5]),
    column: parseInt(tokens[6]),
    doc: tokens[7],
    forth: tokens[3],
    section: parseEnum[IdeCmd]("ide" & capitalizeAscii(tokens[0])))

proc createSuggestApi*(file: string): SuggestApi =
  result = SuggestApi()
  with result:
    process = startProcess(command = "nimsuggest --find {file} --autobind".fmt,
                           workingDir = getCurrentDir(),
                           options = {poUsePath, poEvalCommand})
    port = parseInt(readLine(process.outputStream))

proc call*(self: SuggestApi, command: string, file: string, dirtyFile: string, line: int, column: int): Future[seq[Suggest]] {.async.} =
  let socket = newAsyncSocket()
  waitFor socket.connect("127.0.0.1", Port(self.port))

  discard socket.send("{command} {file};{dirtyFile}:{line}:{column}".fmt & "\c\L", {})
  result = @[]
  var line: string = await socket.recvLine();
  while line != "\r\n" and line != "":
    result.add parseSuggest(line);
    line = await socket.recvLine();
  if (line == ""):
    raise newException(Exception, "Socket closed.")

template createFullCommand(command: untyped) {.dirty.} =
  proc command*(self: SuggestApi, file: string, dirtyfile = "",
                line: int, col: int): Future[seq[Suggest]] =
    return self.call(astToStr(command), file, dirtyfile, line, col)

template createFileOnlyCommand(command: untyped) {.dirty.} =
  proc command*(self: SuggestApi, file: string, dirtyfile = ""): Future[seq[Suggest]] =
    return self.call(astToStr(command), file, dirtyfile, 0, 0)

createFullCommand(sug)
createFullCommand(con)
createFullCommand(def)
createFullCommand(use)
createFullCommand(dus)
createFileOnlyCommand(chk)
createFileOnlyCommand(highlight)
createFileOnlyCommand(outline)
createFileOnlyCommand(known)
