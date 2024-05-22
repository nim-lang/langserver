import osproc,
  strutils,
  strformat,
  times,
  deques,
  sets,
  os,
  asyncnet,
  sequtils,
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
const HighestSupportedNimSuggestProtocolVersion = 4

# coppied from Nim repo
type
  PrefixMatch* {.pure.} = enum
    None,   ## no prefix detected
    Abbrev  ## prefix is an abbreviation of the symbol
    Substr, ## prefix is a substring of the symbol
    Prefix, ## prefix does match the symbol

  IdeCmd* = enum
    ideNone, ideSug, ideCon, ideDef, ideUse, ideDus, ideChk, ideMod,
    ideHighlight, ideOutline, ideKnown, ideMsg, ideProject, ideType, ideExpand
  NimsuggestCallback = proc(self: Nimsuggest): void {.gcsafe.}

  Suggest* = ref object
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
    endLine*: int
    endCol*: int
    inlayHintInfo*: SuggestInlayHint

  SuggestCall* = ref object
    commandString: string
    future: Future[seq[Suggest]]
    command: string

  SuggestInlayHintKind* = enum
    sihkType = "Type",
    sihkParameter = "Parameter"
    sihkException = "Exception"

  SuggestInlayHint* = ref object
    kind*: SuggestInlayHintKind
    line*: int                   # Starts at 1
    column*: int                 # Starts at 0
    label*: string
    paddingLeft*: bool
    paddingRight*: bool
    allowInsert*: bool
    tooltip*: string

  NimSuggestCapability* = enum 
    nsCon = "con",
    nsExceptionInlayHints = "exceptionInlayHints"

  Nimsuggest* = ref object
    failed*: bool
    errorMessage*: string
    checkProjectInProgress*: bool
    needsCheckProject*: bool
    openFiles*: OrderedSet[string]
    successfullCall*: bool
    errorCallback: NimsuggestCallback
    process: Process
    port: int
    root: string
    requestQueue: Deque[SuggestCall]
    processing: bool
    timeout: int
    timeoutCallback: NimsuggestCallback
    protocolVersion*: int
    capabilities*: set[NimSuggestCapability]


template benchmark(benchmarkName: string, code: untyped) =
  block:
    debug "Started...", benchmark = benchmarkName
    let t0 = epochTime()
    code
    let elapsed = epochTime() - t0
    let elapsedStr = elapsed.formatFloat(format = ffDecimal, precision = 3)
    debug "CPU Time", benchmark = benchmarkName, time = elapsedStr

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
  of "skField": SymbolKind.Field
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

proc parseSuggestDef*(line: string): Suggest =
  let tokens = line.split('\t');
  if tokens.len < 8:
    error "Failed to parse: ", line = line
    raise newException(ValueError, fmt "Failed to parse line {line}")
  result = Suggest(
    qualifiedPath: tokens[2].parseQualifiedPath,
    filePath: tokens[4],
    line: parseInt(tokens[5]),
    column: parseInt(tokens[6]),
    doc: tokens[7].unescape(),
    forth: tokens[3],
    symKind: tokens[1],
    section: parseEnum[IdeCmd]("ide" & capitalizeAscii(tokens[0])))
  if tokens.len == 11:
    result.endLine = parseInt(tokens[9])
    result.endCol = parseInt(tokens[10])

proc parseSuggestInlayHint*(line: string): SuggestInlayHint =
  let tokens = line.split('\t');
  if tokens.len < 8:
    error "Failed to parse: ", line = line
    raise newException(ValueError, fmt "Failed to parse line {line}")
  result = SuggestInlayHint(
    kind: parseEnum[SuggestInlayHintKind](capitalizeAscii(tokens[0])),
    line: parseInt(tokens[1]),
    column: parseInt(tokens[2]),
    label: tokens[3],
    paddingLeft: parseBool(tokens[4]),
    paddingRight: parseBool(tokens[5]),
    allowInsert: parseBool(tokens[6]),
    tooltip: tokens[7])

proc name*(sug: Suggest): string =
  return sug.qualifiedPath[^1]

proc markFailed(self: Nimsuggest, errMessage: string) =
  self.failed = true
  self.errorMessage = errMessage
  if self.errorCallback != nil:
    self.errorCallback(self)

proc readPort(param: tuple[pipe: AsyncPipe, process: Process]) {.thread.} =
  try:
    var line = param.process.outputStream.readLine & "\n"
    writeToPipe(param.pipe, line[0].addr, line.len)
  except IOError:
    error "Failed to read nimsuggest port"
    var msg = failedToken & "\n"
    writeToPipe(param.pipe, msg[0].addr, msg.len)

proc logStderr(param: tuple[root: string, process: Process]) {.thread.} =
  try:
    var line = param.process.errorStream.readLine
    while line != "\0":
      stderr.writeLine fmt ">> {line}"
      line = param.process.errorStream.readLine
  except IOError:
    discard

proc stop*(self: Nimsuggest) =
  debug "Stopping nimsuggest for ", root = self.root
  try:
    self.process.kill()
    self.process.close()
  except Exception:
    discard

proc doWithTimeout*[T](fut: Future[T], timeout: int, s: string): owned(Future[bool]) =
  var retFuture = newFuture[bool]("asyncdispatch.`doWithTimeout`")
  var timeoutFuture = sleepAsync(timeout)
  fut.addCallback do ():
    if not retFuture.finished:
      retFuture.complete(true)

  timeoutFuture.addCallback do ():
    if not retFuture.finished:
      retFuture.complete(false)

  return retFuture

proc detectNimsuggestVersion(root: string,
                             nimsuggestPath: string,
                             workingDir: string): int {.gcsafe.} =
  var process = startProcess(command = nimsuggestPath,
                             workingDir = workingDir,
                             args = @[root, "--info:protocolVer"],
                             options = {poUsePath})
  var l: string
  if not process.outputStream.readLine(l):
    l = ""
  var exitCode = process.waitForExit()
  if exitCode != 0 or l == "":
    # older versions of NimSuggest don't support the --info:protocolVer option
    # use protocol version 3 with them
    return 3
  else:
    return parseInt(l)

proc getNimsuggestCapabilities*(nimsuggestPath: string): 
  set[NimSuggestCapability] {.gcsafe.} =

  proc parseCapability(c: string): Option[NimSuggestCapability] =
    debug "Parsing nimsuggest capability", capability=c
    try:
      result = some(parseEnum[NimSuggestCapability](c))
    except:
      debug "Capability not supported. Ignoring.", capability=c
      result = none(NimSuggestCapability)

  var process = startProcess(command = nimsuggestPath,
                             args = @["--info:capabilities"],
                             options = {poUsePath})
  var l: string
  if not process.outputStream.readLine(l):
    l = ""
  var exitCode = process.waitForExit()
  if exitCode == 0: 
    # older versions of NimSuggest don't support the --info:capabilities option
    for cap in l.split(" ").mapIt(parseCapability(it)):
      if cap.isSome:
        result.incl(cap.get)

proc createNimsuggest*(root: string,
                       nimsuggestPath: string,
                       timeout: int,
                       timeoutCallback: NimsuggestCallback,
                       errorCallback: NimsuggestCallback,
                       workingDir = getCurrentDir(),
                       enableLog: bool = false,
                       enableExceptionInlayHints: bool = false): Future[Nimsuggest] {.async, gcsafe.} =
  var
    pipe = createPipe(register = true, nonBlockingWrite = false)
    thread: Thread[tuple[pipe: AsyncPipe, process: Process]]
    stderrThread: Thread[tuple[root: string, process: Process]]
    input = pipe.asyncPipeInput

  info "Starting nimsuggest", root = root, timeout = timeout, path = nimsuggestPath, 
    workingDir = workingDir

  result = Nimsuggest()
  result.requestQueue = Deque[SuggestCall]()
  result.root = root
  result.timeout = timeout
  result.timeoutCallback = timeoutCallback
  result.errorCallback = errorCallback

  if nimsuggestPath != "":
    result.protocolVersion = detectNimsuggestVersion(root, nimsuggestPath, workingDir)
    if result.protocolVersion > HighestSupportedNimSuggestProtocolVersion:
      result.protocolVersion = HighestSupportedNimSuggestProtocolVersion
    var
      args = @[root, "--v" & $result.protocolVersion, "--autobind"]
    if result.protocolVersion >= 4:
      args.add("--clientProcessId:" & $getCurrentProcessId())
    if enableLog:
      args.add("--log")
    result.capabilities = getNimsuggestCapabilities(nimsuggestPath)
    if nsExceptionInlayHints in result.capabilities:
      if enableExceptionInlayHints:
        args.add("--exceptionInlayHints:on")
      else:
        args.add("--exceptionInlayHints:off")
    result.process = startProcess(command = nimsuggestPath,
                                  workingDir = workingDir,
                                  args = args,
                                  options = {poUsePath})

    # all this is needed to avoid the need to block on the main thread.
    createThread(thread, readPort, (pipe: pipe, process: result.process))

    # copy stderr of log
    createThread(stderrThread, logStderr, (root: root, process: result.process))

    if input.readable:
      let line = await input.readLine
      if line == failedToken:
        result.markFailed "Nimsuggest process crashed."
      else:
        result.port = line.parseInt
        debug "Started nimsuggest", port = result.port, root = root
  else:
    error "Unable to start nimsuggest. Unable to find binary on the $PATH", nimsuggestPath = nimsuggestPath
    result.markFailed fmt "Unable to start nimsuggest. `{nimsuggestPath}` is not present on the PATH"

proc createNimsuggest*(root: string): Future[Nimsuggest] {.gcsafe.} =
  result = createNimsuggest(root, "nimsuggest", REQUEST_TIMEOUT,
                            proc (ns: Nimsuggest) = discard,
                            proc (ns: Nimsuggest) = discard)


proc processQueue(self: Nimsuggest): Future[void] {.async.}=
  debug "processQueue", size = self.requestQueue.len
  while self.requestQueue.len != 0:
    let req = self.requestQueue.popFirst
    logScope:
      command = req.commandString
    if req.future.finished:
      debug "Call cancelled before executed", command = req.command
    elif self.failed:
      debug "Nimsuggest is not working, returning empty result..."
      req.future.complete @[]
    else:
      benchmark req.commandString:
        let socket = newAsyncSocket()
        var res: seq[Suggest] = @[]

        if not self.timeoutCallback.isNil:
          debug "timeoutCallback is set", timeout = self.timeout
          doWithTimeout(req.future, self.timeout, fmt "running {req.commandString}").addCallback do (f: Future[bool]):
            if not f.failed and not f.read():
              debug "Calling restart"
              self.timeoutCallback(self)

        await socket.connect("127.0.0.1", Port(self.port))
        await socket.send(req.commandString & "\c\L")

        const bufferSize = 1024 * 1024 * 4
        var buffer:seq[byte] = newSeq[byte](bufferSize);

        var content = "";
        var received = await socket.recvInto(addr buffer[0], bufferSize)

        while received != 0:
          let chunk = newString(received)
          copyMem(chunk[0].unsafeAddr, buffer[0].unsafeAddr, received)
          content = content & chunk
          received = await socket.recvInto(addr buffer[0], bufferSize)

        for lineStr  in content.splitLines:
          if lineStr != "":
            case req.command
            of "known":
              let sug = Suggest()
              sug.section = ideKnown
              sug.forth = lineStr
              res.add sug
            of "inlayHints":
              res.add Suggest( inlayHintInfo: parseSuggestInlayHint(lineStr) )
            else:
              res.add parseSuggestDef(lineStr)

        if (content == ""):
          self.markFailed "Server crashed/socket closed."
          debug "Server socket closed"
          if not req.future.finished:
            debug "Call cancelled before sending error", command = req.command
            req.future.fail newException(CatchableError, "Server crashed/socket closed.")
        if not req.future.finished:
          debug "Sending result(s)", length = res.len
          req.future.complete res
          self.successfullCall = true
          socket.close()
        else:
          debug "Call was cancelled before sending the result", command = req.command
          socket.close()
  self.processing = false

proc call*(self: Nimsuggest, command: string, file: string, dirtyFile: string,
    line: int, column: int, tag = ""): Future[seq[Suggest]] =
  result = Future[seq[Suggest]]()
  let commandString = if dirtyFile != "":
                        fmt "{command} \"{file}\";\"{dirtyFile}\":{line}:{column}{tag}"
                      else:
                        fmt "{command} \"{file}\":{line}:{column}{tag}"
  self.requestQueue.addLast(
    SuggestCall(commandString: commandString, future: result, command: command))

  if not self.processing:
    self.processing = true
    traceAsyncErrors processQueue(self)

template createFullCommand(command: untyped) {.dirty.} =
  proc command*(self: Nimsuggest, file: string, dirtyfile = "",
                line: int, col: int, tag = ""): Future[seq[Suggest]] =
    return self.call(astToStr(command), file, dirtyfile, line, col, tag)

template createFileOnlyCommand(command: untyped) {.dirty.} =
  proc command*(self: Nimsuggest, file: string, dirtyfile = ""): Future[seq[Suggest]] =
    return self.call(astToStr(command), file, dirtyfile, 0, 0)

template createGlobalCommand(command: untyped) {.dirty.} =
  proc command*(self: Nimsuggest): Future[seq[Suggest]] =
    return self.call(astToStr(command), "-", "", 0, 0)

template createRangeCommand(command: untyped) {.dirty.} =
  proc command*(self: Nimsuggest, file: string, dirtyfile = "",
                startLine, startCol, endLine, endCol: int,
                extra: string): Future[seq[Suggest]] =
    return self.call(astToStr(command), file, dirtyfile, startLine, startCol, fmt ":{endLine}:{endCol}{extra}")

# create commands
createFullCommand(sug)
createFullCommand(con)
createFullCommand(def)
createFullCommand(declaration)
createFullCommand(use)
createFullCommand(expand)
createFullCommand(highlight)
createFullCommand(type)
createFileOnlyCommand(chk)
createFileOnlyCommand(chkFile)
createFileOnlyCommand(changed)
createFileOnlyCommand(outline)
createFileOnlyCommand(known)
createFileOnlyCommand(globalSymbols)
createGlobalCommand(recompile)
createRangeCommand(inlayHints)

proc `mod`*(nimsuggest: Nimsuggest, file: string, dirtyfile = ""): Future[seq[Suggest]] =
  return nimsuggest.call("ideMod", file, dirtyfile, 0, 0)
