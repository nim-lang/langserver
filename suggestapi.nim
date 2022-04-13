import osproc,
  strutils,
  strformat,
  deques,
  os,
  asyncnet,
  streams,
  protocol/enums,
  faststreams/asynctools_adapters,
  faststreams/async_backend,
  faststreams/inputs,
  faststreams/textio,
  asyncdispatch,
  asynctools/asyncpipe,
  ./pipes,
  ./utils,
  chronicles

const REQUEST_TIMEOUT* = 120000

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
    qualifiedPath*: seq[string] # part of 'qualifiedPath'
    filePath*: string
    line*: int                # Starts at 1
    column*: int              # Starts at 0
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

  SuggestCall* = ref object
    commandString: string
    future: Future[seq[Suggest]]
    command: string

  Nimsuggest* = ref object
    process*: Process
    port: int
    root: string
    requestQueue: Deque[SuggestCall]
    processing: bool
    failed*: bool
    timeout*: int
    timeoutCallback*: proc(self: Nimsuggest): void {.gcsafe.}
    errorMessage*: string

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

func nimSymToLSPSymbolKind*(suggest: string): SymbolKind =
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

const failedToken = "::Failed::"

proc parseQualifiedPath*(input: string): seq[string] =
  result = @[]
  var
    item = ""
    escaping = false

  for c in input:
    if c == '`':
      item = item & c
      escaping = not escaping
    elif escaping:
      item = item & c
    elif c == '.':
      result.add item
      item = ""
    else:
      item = item & c

  if item != "":
    result.add item

proc parseSuggest*(line: string): Suggest =
  let tokens = line.split('\t');
  return Suggest(
    qualifiedPath: tokens[2].parseQualifiedPath,
    filePath: tokens[4],
    line: parseInt(tokens[5]),
    column: parseInt(tokens[6]),
    doc: tokens[7].unescape(),
    forth: tokens[3],
    symKind: tokens[1],
    section: parseEnum[IdeCmd]("ide" & capitalizeAscii(tokens[0])))

proc name*(sug: Suggest): string =
  return sug.qualifiedPath[^1]

proc readPort(param: tuple[pipe: AsyncPipe, process: Process]) {.thread.} =
  try:
    var line = param.process.outputStream.readLine & "\n"
    writeToPipe(param.pipe, line[0].addr, line.len)
  except IOError as er:
    error "Failed to read nimsuggest port"
    var msg = failedToken & "\n"
    writeToPipe(param.pipe, msg[0].addr, msg.len)

proc logStderr(param: tuple[root: string, process: Process]) {.thread.} =
  try:
    var line = param.process.errorStream.readLine
    while line != "\0":
      stderr.writeLine fmt "nimsuggest({param.root})>>{line}"
      line = param.process.errorStream.readLine
  except IOError:
    discard

proc stop*(self: Nimsuggest) =
  debug "Stopping nimsuggest for ", root = self.root
  try:
    self.process.terminate()
  except Exception:
    discard

proc withTimeout*[T](fut: Future[T], timeout: int, s: string): owned(Future[bool]) =
  var retFuture = newFuture[bool]("asyncdispatch.`withTimeout`")
  var timeoutFuture = sleepAsync(timeout)
  fut.addCallback do ():
    if not retFuture.finished:
      retFuture.complete(true)

  timeoutFuture.addCallback do ():
    if not retFuture.finished:
      retFuture.complete(false)

  return retFuture

proc createNimsuggest*(root: string,
                       nimsuggestPath: string,
                       timeout: int,
                       timeoutCallback: proc (ns: Nimsuggest): void {.gcsafe.}): Future[Nimsuggest] {.async.} =
  var
    pipe = createPipe(register = true, nonBlockingWrite = false)
    thread: Thread[tuple[pipe: AsyncPipe, process: Process]]
    stderrThread: Thread[tuple[root: string, process: Process]]
    input = pipe.asyncPipeInput
    fullPath = findExe(nimsuggestPath)

  debug "Starting nimsuggest", root = root, timeout = timeout, path = nimsuggestPath, fullPath = fullPath

  result = Nimsuggest()
  result.requestQueue = Deque[SuggestCall]()
  result.root = root
  result.timeout = timeout
  result.timeoutCallback = timeoutCallback

  if fullPath != "":
    result.process = startProcess(command = "{nimsuggestPath} {root} --autobind".fmt,
                                  workingDir = getCurrentDir(),
                                  options = {poUsePath, poEvalCommand})

    # all this is needed to avoid the need to block on the main thread.
    createThread(thread, readPort, (pipe: pipe, process: result.process))

    # copy stderr of log
    createThread(stderrThread, logStderr, (root: root, process: result.process))

    if input.readable:
      let line = await input.readLine
      if line == failedToken:
        result.failed = true
        result.errorMessage = "Nimsuggest process crashed."
      else:
        result.port = line.parseInt
        debug "Started nimsuggest", port = result.port, root = root
  else:
    error "Unable to start nimsuggest. Unable to find binary on the $PATH", nimsuggestPath = nimsuggestPath
    result.failed = true
    result.errorMessage = fmt "Unable to start nimsuggest. `{nimsuggestPath}` is not present on the PATH"

proc createNimsuggest*(root: string): Future[Nimsuggest] =
  result = createNimsuggest(root, "nimsuggest", REQUEST_TIMEOUT) do (ns: Nimsuggest):
    discard

proc processQueue(self: Nimsuggest): Future[void] {.async.}=
  debug "processQueue", size = self.requestQueue.len
  while self.requestQueue.len != 0:
    let req = self.requestQueue.popFirst
    logScope:
      command = req.commandString
    if req.future.finished:
      debug "Call cancelled before executed", command = req.command
    elif self.failed:
      req.future.complete @[]
    else:
      debug "Executing command", command = req.commandString
      let socket = newAsyncSocket()
      var res: seq[Suggest] = @[]

      if not self.timeoutCallback.isNil:
        debug "timeoutCallback is set", timeout = self.timeout
        withTimeout(req.future, self.timeout, fmt "running {req.commandString}").addCallback do (f: Future[bool]):
          debug "timeout future finished", failed = f.failed, finished = f.finished
          if not f.failed and not f.read():
            debug "Calling restart"
            self.timeoutCallback(self)

      await socket.connect("127.0.0.1", Port(self.port))
      await socket.send(req.commandString & "\c\L")

      var lineStr: string = await socket.recvLine()
      while lineStr != "\r\n" and lineStr != "":
        trace "Received line", line = lineStr
        res.add parseSuggest(lineStr)
        lineStr = await socket.recvLine();

      if (lineStr == ""):
        self.failed = true
        self.errorMessage = "Server crashed/socket closed."
        debug "Server socket closed"
        if not req.future.finished:
          debug "Call cancelled before sending error", command = req.command
          req.future.fail newException(CatchableError, "Server crashed/socket closed.")
      if not req.future.finished:
        debug "Sending result(s)", length = res.len
        req.future.complete res
        socket.close()
      else:
        debug "Call was cancelled before sending the result", command = req.command
        socket.close()
  self.processing = false

proc call*(self: Nimsuggest, command: string, file: string, dirtyFile: string,
    line: int, column: int): Future[seq[Suggest]] =
  result = Future[seq[Suggest]]()

  let commandString = fmt "{command} {file};{dirtyFile}:{line}:{column}"
  self.requestQueue.addLast(
    SuggestCall(commandString: commandString, future: result, command: command))

  if not self.processing:
    self.processing = true
    traceAsyncErrors processQueue(self)

template createFullCommand(command: untyped) {.dirty.} =
  proc command*(self: Nimsuggest, file: string, dirtyfile = "",
                line: int, col: int): Future[seq[Suggest]] =
    return self.call(astToStr(command), file, dirtyfile, line, col)

template createFileOnlyCommand(command: untyped) {.dirty.} =
  proc command*(self: Nimsuggest, file: string, dirtyfile = ""): Future[seq[Suggest]] =
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

proc `mod`*(nimsuggest: Nimsuggest, file: string, dirtyfile = ""): Future[seq[Suggest]] =
  return nimsuggest.call("ideMod", file, dirtyfile, 0, 0)
