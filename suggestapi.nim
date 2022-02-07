import osproc,
  strutils,
  with,
  strformat,
  os,
  asyncnet,
  streams,
  protocol/enums,
  faststreams/asynctools_adapters,
  utils,
  faststreams/async_backend,
  faststreams/inputs,
  faststreams/textio,
  asyncdispatch,
  asynctools/asyncpipe,
  ./pipes,
  chronicles

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
    symkind*: string
    scope*, localUsages*, globalUsages*: int # more usages is better
    tokenLen*: int
    version*: int

  SuggestApi* = ref object
    process: Process
    port: int

func nimSymToLSPKind*(suggest: Suggest): CompletionItemKind =
  case suggest.symKind:
  of "skConst": CompletionItemKind.Value
  of "skEnumField": CompletionItemKind.Enum
  of "skForVar": CompletionItemKind.Variable
  of "skIterator": CompletionItemKind.Keyword
  of "skLabel": CompletionItemKind.Keyword
  of "skLet": CompletionItemKind.Value
  of "skMacro": CompletionItemKind.Snippet
  of "skMethod": CompletionItemKind.Method
  of "skParam": CompletionItemKind.Variable
  of "skProc": CompletionItemKind.Function
  of "skResult": CompletionItemKind.Value
  of "skTemplate": CompletionItemKind.Snippet
  of "skType": CompletionItemKind.Class
  of "skVar": CompletionItemKind.Field
  of "skFunc": CompletionItemKind.Function
  else: CompletionItemKind.Property

func nimSymToLSPKind*(suggest: string): SymbolKind =
  case suggest:
  of "skConst": SymbolKind.Constant
  of "skEnumField": SymbolKind.EnumMember
  of "skIterator": SymbolKind.Function
  of "skConverter": SymbolKind.Function
  of "skLet": SymbolKind.Variable
  of "skMacro": SymbolKind.Function
  of "skMethod": SymbolKind.Method
  of "skProc": SymbolKind.Function
  of "skTemplate": SymbolKind.Function
  of "skType": SymbolKind.Class
  of "skVar": SymbolKind.Variable
  of "skFunc": SymbolKind.Function
  else: SymbolKind.Function

func nimSymDetails*(suggest: Suggest): string =
  case suggest.symKind:
  of "skConst": "const " & suggest.qualifiedPath.join(".") & ": " & suggest.forth
  of "skEnumField": "enum " & suggest.forth
  of "skForVar": "for var of " & suggest.forth
  of "skIterator": suggest.forth
  of "skLabel": "label"
  of "skLet": "let of " & suggest.forth
  of "skMacro": "macro"
  of "skMethod": suggest.forth
  of "skParam": "param"
  of "skProc": suggest.forth
  of "skResult": "result"
  of "skTemplate": suggest.forth
  of "skType": "type " & suggest.qualifiedPath.join(".")
  of "skVar": "var of " & suggest.forth
  else: suggest.forth

proc parseSuggest*(line: string): Suggest =
  let tokens = line.split('\t');

  return Suggest(
    qualifiedPath: tokens[2].split("."),
    filePath: tokens[4],
    line: parseInt(tokens[5]),
    column: parseInt(tokens[6]),
    doc: tokens[7].unescape(),
    forth: tokens[3],
    symKind: tokens[1],
    section: parseEnum[IdeCmd]("ide" & capitalizeAscii(tokens[0])))

proc readPort(param: tuple[pipe: AsyncPipe, process: Process]) {.thread.} =
  var line = param.process.outputStream.readLine & "\n"
  writeToPipe(param.pipe, line[0].addr, line.len)

proc createSuggestApi*(root: string): Future[SuggestApi] {.async.} =
  debug "Starting nimsuggest", root = root

  var
    pipe = createPipe(register = true, nonBlockingWrite = false)
    thread: Thread[tuple[pipe: AsyncPipe, process: Process]]

  result = SuggestApi()
  with result:
    process = startProcess(command = "nimsuggest {root} --autobind".fmt,
                           workingDir = getCurrentDir(),
                           options = {poUsePath, poEvalCommand})
    # all this is needed to avoid the need
    createThread(thread, readPort, (pipe: pipe, process: process))
    let input = pipe.asyncPipeInput;
    if input.readable:
      port = input.readLine.await.parseInt
      debug "Started nimsuggest", port = port, root = root

proc call*(self: SuggestApi, command: string, file: string, dirtyFile: string,
    line: int, column: int): Future[seq[Suggest]] {.async.} =
  logScope:
    command = command
    line = line
    column = column
    file = file

  let socket = newAsyncSocket()

  waitFor socket.connect("127.0.0.1", Port(self.port))

  let commandString = fmt "{command} {file};{dirtyFile}:{line}:{column}"
  debug "Calling nimsuggest"
  discard socket.send(commandString & "\c\L")

  result = @[]
  var lineStr: string = await socket.recvLine();
  while lineStr != "\r\n" and lineStr != "":
    result.add parseSuggest(lineStr);
    lineStr = await socket.recvLine();

  if (lineStr == ""):
    raise newException(Exception, "Socket closed.")

  debug "Received result(s)", length = result.len

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

proc `mod`*(suggestApi: SuggestApi, file: string, dirtyfile = ""): Future[seq[Suggest]] =
  return suggestApi.call("ideMod", file, dirtyfile, 0, 0)
