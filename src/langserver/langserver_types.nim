import std/[json, options, tables, sets, streams]
import chronos
import chronos/asyncproc
import json_rpc/servers/socketserver

import ../protocol/types
import ../nimsuggest/nimsuggest_types
import ../nimble/nimble
import ./[messaging_types, configuration_types]

##[
LRU = Least Recently Used — a cache eviction policy where, when you need to free a slot, you discard whichever entry was accessed least recently.
]##

type
  LanguageServerCapabiities* = object
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
    workspaceConfiguration*: Option[NlsConfig] 
    didChangeConfigurationRegistrationRequest*: bool

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
    projectFile*: Future[string]
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
  
##[
LanguageServerProjects
Nimsuggest process lifecycle — spawning, crash tracking, idle eviction.  No knowledge of what the editor has open.

projectFiles
Central registry of running (or starting) nimsuggest instances, keyed by project entry-point path. 
Two kinds of entries exist: 
- Canonical: key == project.file — a real running instance.
- Redirect alias: key != project.file — points at another project's instance after a "kill and replace" standalone restart. Created so files whose projectFile future already resolved to the old key can still reach a working nimsuggest.  Always check proj.file == key before treating an entry as canonical.
    
entryPoints
Project entry points discovered from nimble dump during initialized. Used by initNimsuggestInstances to pre-spawn nimsuggest, and by removeIdleNimsuggests to protect entry-point instances from eviction.
    
failTable
projectFile → crash count. When count >= MaxFails, getNimsuggestInner gives up and falls back to the LRU instance instead of retrying. Cleared on successful nimsuggest initialisation.
    
crashedFiles
projectFile → set of file URIs that caused a nimsuggest SIGSEGV.  Blocked files are skipped during re-registration after a restart. Cleared by: didSave (per file), explicit restart (per project).
    
nimDumpCache
nimble file path → cached dump result. Avoids repeated SAT solver runs for the same .nimble file within a session. Invalidated on didRenameFiles / didDeleteFiles for .nimble files.

]##


type
  ProjectFile* {.borrow.} = distinct string 
  LanguageServerNimSuggest* = object
    nimsuggestInstances*: Table[ProjectFile, Project]
    entryPoints*: seq[ProjectFile]
    failTable*: Table[ProjectFile, int]
    crashedFiles*: Table[ProjectFile, HashSet[string]]
    nimDumpCache*: Table[ProjectFile, NimbleDumpInfo] 

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
    inlayHintsRefreshRequest*: Future[JsonNode]
    projectErrors*: seq[ProjectError]
    lastStatusSent: JsonNode

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
    capabilities*: LanguageServerCapabiities
    configurations*: LanguageServerConfigurations
    transport*: LanguageServerTransport
    files*: LanguageServerFiles
    nimsuggest*: LanguageServerNimSuggest
    messaging*: LanguageServerMessaging
    
    notify*: NotifyAction
    call*: CallAction
    onExit*: OnExitCallback
    testRunProcess*: Option[AsyncProcessRef]
    cmdLineClientProcessId*: Option[int]
    
    checkInProgress*: bool
    isShutdown*: bool
    