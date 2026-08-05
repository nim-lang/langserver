import std/[json, options, tables, sets, streams]
import chronos
import chronos/asyncproc
import json_rpc/servers/socketserver

import ../protocol/types
import ../nim_tools/nimble/nimble_types
import ./[messaging_types, configuration_types, queue_types]

##[
LRU = Least Recently Used — a cache eviction policy where, when you need to free a slot, you discard whichever entry was accessed least recently.
]##

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

##[
NlsFileInfo fields
projectFile: Future[string] — the path of the nimsuggest entry point responsible for this file. Future because getProjectFile may need to call nimble dump (async I/O) to determine it. Multiple concurrent requests for the same file all await the same future. In a queue model: plain string, resolved synchronously before the didOpen handler returns.

changed: bool — whether there are unsaved edits (stash file is newer than disk). Plain bool, correctly typed.

fingerTable: seq[seq[tuple[u16pos, offset: int]]] — UTF-8 to UTF-16 position mapping, rebuilt on every didChange. Needed because LSP uses UTF-16 offsets but Nim source is UTF-8. Plain data, correctly typed.

cancelFileCheck: Future[void] — a Chronos cancellation token for the deferred checkFile timer. In a queue model this would be a bool pendingCheck flag or a queue item ID that can be dequeued.

checkInProgress: bool — prevents a second checkFile from starting while one is already running for this file. Correctly typed.

needsChecking: bool — set when a check is requested while checkInProgress is true; causes a follow-up check to be scheduled when the current one finishes. Correctly typed.

textDocument: TextDocumentItem — the original didOpen metadata (URI, language ID, version, initial content). Plain data, correctly typed.
]##
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

##[
LanguageServerFiles
Pure file tracking — what the editor has open and their stash state.  No knowledge of nimsuggest processes.
    
openFiles
LSP ground truth: every URI VS Code currently has open.
uri → file metadata (projectFile future, stash state, finger table).
    
idleOpenFiles
Files evicted when their nimsuggest was stopped by idle timeout. tryGetNimsuggest silently re-opens them via didOpenFile on next access.
    
filesWithDiags
URIs that currently have diagnostics published to VS Code.  Needed so closing/fixing a file can send empty publishDiagnostics to clear squiggles even after the file is removed from openFiles.
    
storageDir
Filesystem path where stash files (unsaved edits) are written.  Stash path = storageDir / (hash(uri).toHex & ".nim")
]##

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
      ## Global thin-dispatcher queue. processMessage enqueues here;
      ## processLspMessages asyncSpawns runRpc for each item without awaiting.

    notify*: NotifyAction
    call*: CallAction
    onExit*: OnExitCallback
    testRunProcess*: Option[AsyncProcessRef]
    cmdLineClientProcessId*: Option[int]

    checkInProgress*: bool
    isShutdown*: bool
    nimDumpCache*: Table[string, NimbleDumpInfo]
