import std/[json, options, tables, sets, streams]
import chronos
import chronos/asyncproc
import json_rpc/servers/socketserver

import ../protocol/types
# import ../nim_tools/nimble/nimble_types
import ../configurations/configuration_types
import ./[query_types]

type
  CommandLineParams* = object
    clientProcessId*: Option[int]
    mode*: Option[ServerMode]
    transport*: Option[TransportMode]
    port*: Port #only for sockets

  ServerMode* = enum
    lsp = "lsp"
    mcp = "mcp"

  TransportMode* = enum
    stdio = "stdio"
    socket = "socket"

  ReadStdinContext* = object
    onStdReadSignal*: ThreadSignalPtr #used by the thread to notify it read from the std
    onMainReadSignal*: ThreadSignalPtr
      #used by the main thread to notify it read the value from the signal
    value*: cstring

  PendingRequestState* = enum
    prsOnGoing = "OnGoing"
    prsCancelled = "Cancelled"
    prsComplete = "Complete"

  PendingRequest* = object
    id*: uint
    name*: string
    request*: Future[JsonString]
    projectFile*: Option[string]
    startTime*: DateTime
    endTime*: DateTime
    state*: PendingRequestState
    query*: Option[NimsuggestQuery]

  LspDispatchItem* = object
    dispatch*: proc(): Future[void] {.gcsafe, raises: [].}


type
  LanguageServerCapabilities* = object
    case serverMode*: ServerMode
    of lsp:
      lspClientCapabilities*: LspClientCapabilities
      lspServerCapabilities*: LspServerCapabilities
      lspInitializeParams*: LspInitializeParams
    of mcp:
      mcpClientCapabilities*: McpClientCapabilities
      mcpServerCapabilities*: McpServerCapabilities
      mcpInitializeParams*: McpInitializeParams
    extensionCapabilities*: set[LspExtensionCapability]

  LanguageServerConfigurations* = object
    currentConfig*: Option[NlsConfig]
      ## Parsed config. none until first workspace/configuration response arrives.
    configReady*: AsyncEvent
      ## Fired when currentConfig is first populated, and re-fired after each change.

type
  NlsFileInfo* = ref object of RootObj
    slot*: NimsuggestSlot
      ## The pool slot responsible for this file. Assigned synchronously during
      ## didOpenFile. Never nil after assignment.
    changed*: bool
    fingerTable*: seq[seq[tuple[u16pos, offset: int]]]
    cancelFileCheck*: Future[void]
    checkInProgress*: bool
    needsChecking*: bool
    textDocument*: TextDocumentItem

type
  LanguageServerFiles* = object
    openFiles*: Table[string, NlsFileInfo]
    idleOpenFiles*: Table[string, NlsFileInfo]
    filesWithDiags*: HashSet[string]
    storageDir*: string
  
type
  LanguageServerTransport* = object
    srv*: RpcSocketServer
    case transportMode*: TransportMode
    of socket:
      socketTransport*: StreamTransport
    of stdio:
      outStream*: FileStream
      stdinContext*: ptr ReadStdinContext

  LanguageServerMessaging* = object
    pendingRequests*: Table[uint, PendingRequest]
    responseMap*: TableRef[string, Future[JsonNode]]
    responseNames*: TableRef[string, string]
      ## Parallel to responseMap: maps request-id → RPC method name.
      ## Used to include the method name in "id not found" error logs.
    inlayHintsRefreshRequest*: Future[JsonNode]
    projectErrors*: seq[ProjectError]
    lastStatusSent*: JsonNode

type
  Certainty* = enum
    None
    Folder
    Cfg
    Nimble

  OnExitCallback* = proc(): Future[void] {.gcsafe, raises: [].}
    #To be called when the server is shutting down
  NotifyAction* = proc(name: string, params: JsonNode) {.gcsafe, raises: [].}
    #Send a notification to the client
  CallAction* =
    proc(name: string, params: JsonNode): Future[JsonNode] {.gcsafe, raises: [].}
    #Send a request to the client

type
  LanguageServer* = ref object
    capabilities*: LanguageServerCapabilities
    configurations*: LanguageServerConfigurations
    transport*: LanguageServerTransport
    files*: LanguageServerFiles
    pool*: NimsuggestPool
    messaging*: LanguageServerMessaging
    lspQueue*: AsyncQueue[LspDispatchItem]
    langserverQueue*: AsyncQueue[LangserverQuery]
    
    notify*: NotifyAction
    call*: CallAction
    onExit*: OnExitCallback
    testRunProcess*: Option[AsyncProcessRef]
    cmdLineClientProcessId*: Option[int]

    checkInProgress*: bool
    isShutdown*: bool
    nimDumpCache*: Table[string, NimbleDumpInfo]
