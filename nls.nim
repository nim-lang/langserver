import
  json_rpc/streamconnection,
  streams,
  sugar,
  os,
  uri,
  faststreams/async_backend,
  faststreams/textio,
  faststreams/inputs,
  faststreams/outputs,
  faststreams/asynctools_adapters,
  protocol/enums,
  protocol/types

type
  UriParseError* = object of Defect
    uri: string

proc copyStdioToPipe(pipe: AsyncPipe) {.thread.} =
  var
    inputStream = newFileStream(stdin)
    ch = "^"

  ch[0] = inputStream.readChar();
  while ch[0] != '\0':
    discard waitFor write(pipe, ch[0].addr, 1)
    ch[0] = inputStream.readChar();

proc partial[A, B, C] (fn: proc(a: A, b: B): C {.gcsafe.}, a: A): proc (b: B) : C {.gcsafe, raises: [Defect, CatchableError, Exception].} =
  return
    proc(b: B): C {.gcsafe, raises: [Defect, CatchableError, Exception].} =
      return fn(a, b)

proc uriToPath(uri: string): string =
  ## Convert an RFC 8089 file URI to a native, platform-specific, absolute path.
  #let startIdx = when defined(windows): 8 else: 7
  #normalizedPath(uri[startIdx..^1])
  let parsed = uri.parseUri
  if parsed.scheme != "file":
    var e = newException(UriParseError, "Invalid scheme: " & parsed.scheme & ", only \"file\" is supported")
    e.uri = uri
    raise e
  if parsed.hostname != "":
    var e = newException(UriParseError, "Invalid hostname: " & parsed.hostname & ", only empty hostname is supported")
    e.uri = uri
    raise e
  return normalizedPath(
    when defined(windows):
      parsed.path[1..^1]
    else:
      parsed.path).decodeUrl

type
  LanguageServer* = ref object
   clientCapabilities: ClientCapabilities

proc initialize(ls: LanguageServer, params: InitializeParams):
    Future[InitializeResult] {.async} =
  return InitializeResult(
    capabilities: ServerCapabilities(
      textDocumentSync: %TextDocumentSyncOptions(
        openClose: some(true),
        change: some(TextDocumentSyncKind.Full.int),
        willSave: some(false),
        willSaveWaitUntil: some(false),
        save: some(SaveOptions(includeText: some(true)))),
      hoverProvider: some(true),
      completionProvider: CompletionOptions(
        resolveProvider: some(false),
        triggerCharacters: @["."]),
      signatureHelpProvider: SignatureHelpOptions(triggerCharacters: @["(", ","]),
      definitionProvider: some(true),
      referencesProvider: some(true),
      documentSymbolProvider: some(true),
      renameProvider: some(true)))

proc registerLanguageServerHandlers*(connection: StreamConnection) =
  let ls = LanguageServer()
  connection.register("initialize", partial(initialize, ls))

when isMainModule:
  var
    pipe = createPipe(register = true)
    stdioThread: Thread[AsyncPipe]

  createThread(stdioThread, copyStdioToPipe, pipe)

  let connection = StreamConnection.new(asyncPipeInput(pipe),
                                        Async(fileOutput(stdout, allowAsyncOps = true)));
  waitFor connection.start()
