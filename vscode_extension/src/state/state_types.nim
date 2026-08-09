## Types for extension state, this should either get fleshed out or removed
import std/[options, times, strutils, jsconsole, tables]
import platform/vscodeApi

from platform/languageClientApi import VscodeLanguageClient

type
  # Backend* = cstring
  # Timestamp* = cint
  # NimsuggestId* = cstring

  # PendingRequestState* = enum
  #   prsOnGoing = "OnGoing"
  #   prsCancelled = "Cancelled"
  #   prsComplete = "Complete"

  PendingRequestStatus* = object
    name*: cstring
    projectFile*: cstring
    time*: cstring
    state*: cstring

  NimSuggestStatus* = object
    projectFile*: cstring
    capabilities*: seq[cstring]
    version*: cstring
    path*: cstring
    port*: int32
    openFiles*: seq[cstring]
    unknownFiles*: seq[cstring]

  ProjectError* = object
    projectFile*: cstring
    errorMessage*: cstring
    lastKnownCmd*: cstring

  NimLangServerStatus* = object
    version*: cstring
    lspPath*: cstring
    nimsuggestInstances*: seq[NimSuggestStatus]
    openFiles*: seq[cstring]
    extensionCapabilities*: seq[cstring]
    pendingRequests*: seq[PendingRequestStatus]
    projectErrors*: seq[ProjectError]

  LspItem* = ref object of TreeItem
    instance*: Option[NimSuggestStatus]
    notification*: Option[Notification]

  Notification* = object
    message*: cstring
    kind*: cstring
    id*: cstring
    date*: DateTime

  NimLangServerStatusProvider* = ref object of JsObject
    status*: Option[NimLangServerStatus]
    notifications*: seq[Notification]
    lastId*: int32 # onDidChangeTreeData*: EventEmitter

  LSPVersion* = tuple[major: int, minor: int, patch: int]

  NimbleTask* = object
    name*: cstring
    description*: cstring
    isRunning*: bool
  
  RunTaskParams* = object
    command*: seq[cstring] #command and args
  
  RunTaskResult* = object
    command*: seq[cstring] #command and args
    output*: seq[cstring] #output lines

  TestInfo* = object
    name*: cstring
    line*: int
    file*: cstring

  TestSuiteInfo* = object
    name*: cstring #The suite name, empty if it's a global test
    tests*: seq[TestInfo]

  TestProjectInfo* = object
    entryPoint*: cstring
    suites*: JsAssoc[cstring, TestSuiteInfo]
    error*: cstring

  ListTestsParams* = object
    entryPoint*: cstring #can be patterns? if empty we could do the same as nimble does or just run `nimble test args`

  ListTestsResult* = object
    projectInfo*: TestProjectInfo

  RunTestResult* = object
    name*: cstring
    time*: float
    failure*: cstring

  RunTestSuiteResult* = object
    name*: cstring
    tests*: int
    failures*: int
    errors*: int
    skipped*: int
    time*: float
    testResults*: seq[RunTestResult]
  
  RunTestParams* = object
    entryPoint*: cstring
    suiteName*: cstring #Optional, if provided, only run tests in the suite
    testNames*: seq[cstring] #Optional, if provided, only run the specific tests

  RunTestProjectResult* = object
    suites*: seq[RunTestSuiteResult]
    fullOutput*: cstring

  CancelTestResult* = object
    cancelled*: bool

  LSPInstallPathKind* = enum
    lspPathSetting, lspPathLocal, lspPathGlobal, lspPathInvalid

  LspExtensionCapability* = enum #List of extensions the lsp server support.
    excNone = "None"
    excRestartSuggest = "RestartSuggest"
    excNimbleTask = "NimbleTask"
    excRunTests = "RunTests"
    
  ExtensionState* = ref object
    ctx*: VscodeExtensionContext
    config*: VscodeWorkspaceConfiguration
    channel*: VscodeOutputChannel
    lspChannel*: VscodeOutputChannel
    client*: VscodeLanguageClient
    installPerformed*: bool
    nimDir*: string
      # Nim used directory. Extracted on activation from nimble. When it's "", means nim in the PATH is used.
    statusProvider*: NimLangServerStatusProvider
    lspVersion*: LSPVersion
    lspExtensionCapabilities*: set[LspExtensionCapability]
    nimbleTasks*: seq[NimbleTask]
    propagatedDecorations*: Table[cstring, seq[VscodeTextEditorDecorationType]]
    extensionReady*: bool
    onExtensionReadyHooks*: seq[proc()] #Called when the extension has stablished the connection with the lsp server and is initialized
    dumpTestEntryPoint*: cstring #Extracted from nimble dump. 
