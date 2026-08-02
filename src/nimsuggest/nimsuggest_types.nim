import std/[options, sets, times, deques]

import chronos
import chronos/asyncproc

import ../protocol/types

const REQUEST_TIMEOUT* = 120000
const HighestSupportedNimSuggestProtocolVersion = 4

# copied from Nim repo
type
  PrefixMatch* {.pure.} = enum
    None ## no prefix detected
    Abbrev ## prefix is an abbreviation of the symbol
    Substr ## prefix is a substring of the symbol
    Prefix ## prefix does match the symbol

  IdeCmd* = enum
    ideNone
    ideSug
    ideCon
    ideDef
    ideUse
    ideDus
    ideChk
    ideMod
    ideHighlight
    ideOutline
    ideKnown
    ideMsg
    ideProject
    ideType
    ideExpand

  NimsuggestCallback* = proc(self: Nimsuggest): void {.gcsafe, raises: [].}
  ProjectCallback* = proc(self: Project): void {.gcsafe, raises: [].}

  Suggest* = ref object
    section*: IdeCmd
    qualifiedPath*: seq[string] # part of 'qualifiedPath'
    filePath*: string
    line*: int # Starts at 1
    column*: int # Starts at 0
    doc*: string # Not escaped (yet)
    forth*: string # type
    quality*: range[0 .. 100] # matching quality
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
    sihkType = "Type"
    sihkParameter = "Parameter"
    sihkException = "Exception"

  SuggestInlayHint* = ref object
    kind*: SuggestInlayHintKind
    line*: int # Starts at 1
    column*: int # Starts at 0
    label*: string
    paddingLeft*: bool
    paddingRight*: bool
    allowInsert*: bool
    tooltip*: string

  NimsuggestImpl* = object
    checkProjectInProgress*: bool
    needsCheckProject*: bool
    openFiles*: OrderedSet[string]
    successfullCall*: bool
    port*: int
    root: string
    requestQueue: Deque[SuggestCall]
    processing: bool
    timeout: int
    timeoutCallback: NimsuggestCallback
    protocolVersion*: int
    capabilities*: set[NimSuggestCapability]
    nimSuggestPath*: string
    version*: string
    project*: Project

  NimSuggest* = ref NimsuggestImpl

  Project* = ref object
    ns*: Future[NimSuggest]
    file*: string
    process*: AsyncProcessRef
    errorCallback*: Option[ProjectCallback]
    errorMessage*: string
    failed*: bool
    lastCmd*: string
    lastCmdDate*: Option[DateTime]
  
