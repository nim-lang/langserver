import std/jsffi
import js/[jsPromise, jsNode]
import vscodeApi
export jsffi, jsPromise, jsNode

# shim for https://github.com/microsoft/vscode-languageserver-node

type
  VscodeLanguageClient* = ref VscodeLanguageClientObj
  VscodeLanguageClientObj {.importc.} = object of JsRoot
  VscodeLanguageClientMiddleware* = ref VscodeLanguageClientMiddlewareObj
  VscodeLanguageClientMiddlewareObj {.importc.} = object of JsObject
    provideInlayHints*: proc(document: JsObject, viewPort: JsObject, token: JsObject, next: JsObject): Promise[seq[InlayHint]]

  TransportKind* {.pure.} = enum
    stdio = 0
    ipc = 1
    pipe = 2
    socket = 3

  ExecutableOptions* = ref ExecutableOptionsObj
  ExecutableOptionsObj {.importc.} = object of JsObject
    shell*: bool

  Executable* = ref ExecutableObj
  ExecutableObj {.importc.} = object of JsObject
    command*: cstring
    transport*: TransportKind
    options*: ExecutableOptions

  ServerOptions* = ref ServerOptionsObj
  ServerOptionsObj* {.importc.} = object of JsObject
    run*: Executable
    debug*: Executable

  DocumentFilter* = ref DocumentFilterObj
  DocumentFilterObj* {.importc.} = object of JsObject
    language*: cstring
    scheme*: cstring

  LanguageClientOptions* {.importc.} = ref LanguageClientOptionsObj
  LanguageClientOptionsObj* {.importc.} = object of JsObject
    documentSelector*: seq[DocumentFilter]
    outputChannel*: VscodeOutputChannel
  
  InlayHint* = ref object of JsRoot
    position*: VscodePosition
    label*: cstring  # Can be string or InlayHintLabelPart[]
    kind*: InlayHintKind
    textEdits*: seq[VscodeTextEdit]
    tooltip*: cstring
    paddingLeft*: bool
    paddingRight*: bool

  InlayHintLabel* = ref object of JsRoot  # Union type: string | InlayHintLabelPart[]

  InlayHintLabelPart* = ref object of JsRoot
    value*: cstring
    tooltip*: cstring
    location*: VscodeLocation
    command*: VscodeCommands

  InlayHintKind* {.pure.} = enum
    Type = 1
    Parameter = 2


proc newLanguageClient*(
  cl: VscodeLanguageClient,
  name: cstring,
  description: cstring,
  serverOptions: ServerOptions,
  clientOptions: LanguageClientOptions,
): VscodeLanguageClient {.importcpp: "(new #.LanguageClient(@))".}

proc newLanguageClient*(
  cl: VscodeLanguageClient,
  name: cstring,
  description: cstring,
  serverOptions: proc(): Future[ServerOptions],
  clientOptions: LanguageClientOptions,
): VscodeLanguageClient {.importcpp: "(new #.LanguageClient(@))".}

proc start*(s: VscodeLanguageClient): Promise[void] {.importcpp: "#.start()".}
proc stop*(s: VscodeLanguageClient): Promise[void] {.importcpp: "#.stop()".}
proc sendRequest*(
  s: VscodeLanguageClient, m: cstring, params: JsObject
): Future[JsObject] {.importcpp: "#.sendRequest(@)".}

proc onNotification*(
  s: VscodeLanguageClient, m: cstring, cb: proc(data: JsObject)
) {.importcpp: "#.onNotification(@)".}

proc onRequest*(
  s: VscodeLanguageClient, m: cstring, cb: proc(data: JsObject): Future[JsObject]
) {.importcpp: "#.onRequest(@)".}

var vscodeLanguageClient*: VscodeLanguageClient =
  require("vscode-languageclient/node").to(VscodeLanguageClient)
