import osproc, strutils, with, strformat, net, os, streams

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

type
  SuggestApi = ref object
    process: Process
    socket: Socket

proc parseSuggest*(line: string): Suggest =
  let tokens = line.split('\t');
  return Suggest(
    # qualifiedPath: ,
    filePath: tokens[4],
    line: parseInt(tokens[5]),
    column: parseInt(tokens[6]),
    doc: tokens[7],
    forth: tokens[3],
    section: parseEnum[IdeCmd]("ide" & capitalizeAscii(tokens[0])))

proc createSuggestApi*(command: string): SuggestApi =
  result = SuggestApi()
  with result:
    process = startProcess(command = command,
                           workingDir = getCurrentDir(),
                           options = {poUsePath, poEvalCommand})
    let port = parseInt(readLine(process.outputStream))
    socket = newSocket()
    socket.connect("127.0.0.1", Port(port))

proc call*(self: SuggestApi, command: string, file: string, dirtyFile: string, line: int, column: int): seq[Suggest] =
  self.socket.send("{command} {file}:{line}:{column}\n".fmt)

  result = @[]

  var line: string;
  self.socket.readLine(line);
  while line != "\r\n" and line != "":
    result.add parseSuggest(line);
    self.socket.readLine(line);
  if (line == ""):
    raise newException(Exception, "Socket closed.")

# proc createSuggestApi() : SuggestApi =
