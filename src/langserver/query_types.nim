import chronos
import ../nim_tools/nimsuggest/nimsuggest_types
import ../protocol/types

# === NIMSUGGEST QUERIES ===
type
  FilePosition* = object
    line*: int  ## 1-based (nimsuggest convention)
    col*: int   ## UTF-8 byte column

  NimsuggestQueryKind* {.pure.} = enum
    SUGGEST           ## sug          — completion items at position
    DEFINITION        ## def          — go-to-definition
    DECLARATION       ## declaration  — go-to-declaration
    TYPE_DEFINITION   ## type         — go-to-type-definition
    REFERENCES        ## use          — find all references
    DOCUMENT_SYMBOLS  ## outline      — file symbol tree
    WORKSPACE_SYMBOLS ## globalSymbols — workspace-wide symbol search
    HOVER              ## highlight — symbol info at position
    DOCUMENT_HIGHLIGHT ## highlight — all occurrences in file
    SIGNATURE_HELP     ## con        — overload list at call site
    INLAY_HINTS        ## inlayHints — type / parameter / exception hints
    EXPAND             ## expand — macro expansion at position
    CHANGED            ## changed — notify nimsuggest of unsaved edits (stash)
    CHECK_FILE         ## chkFile — per-file diagnostics
    CHECK_PROJECT      ## chk     — full project diagnostics
    RECOMPILE          ## recompile — force full in-process recompile
    KNOWN              ## known     — is this file in the module graph?

  NimsuggestQuery* = ref object
    id*: uint
    uri*: string
      ## Source URI. Used to resolve the on-disk path and stash path.
    dirtyFile*: string
      ## Stash path when openFiles[uri].changed is true, else "".
    responseFuture*: Future[seq[Suggest]]
      ## Completed by the query processor when nimsuggest replies.
    cancelled*: bool
      ## Set by $/cancelRequest. processQueries completes responseFuture
      ## with @[] immediately if true. Safe across coroutines (ref + single-threaded).
    case kind*: NimsuggestQueryKind
    of NimsuggestQueryKind.SUGGEST,
       NimsuggestQueryKind.DEFINITION,
       NimsuggestQueryKind.DECLARATION,
       NimsuggestQueryKind.TYPE_DEFINITION,
       NimsuggestQueryKind.REFERENCES,
       NimsuggestQueryKind.HOVER,
       NimsuggestQueryKind.DOCUMENT_HIGHLIGHT,
       NimsuggestQueryKind.SIGNATURE_HELP:
      position*: FilePosition
    of NimsuggestQueryKind.INLAY_HINTS:
      inlayHints*: tuple[start, finish: FilePosition, options: string]
    of NimsuggestQueryKind.EXPAND:
      expand*: tuple[position: FilePosition, tag: string]
    of NimsuggestQueryKind.DOCUMENT_SYMBOLS,
       NimsuggestQueryKind.WORKSPACE_SYMBOLS,
       NimsuggestQueryKind.CHANGED,
       NimsuggestQueryKind.CHECK_FILE,
       NimsuggestQueryKind.CHECK_PROJECT,
       NimsuggestQueryKind.RECOMPILE,
       NimsuggestQueryKind.KNOWN:
      discard

# === FILE ACCESS QUERIES ===
type
  FileAccessQueryKind* {.pure.} = enum
    DID_OPEN
    DID_CHANGE
    DID_SAVE
    DID_CLOSE
    WILL_SAVE_WAIT_UNTIL
    DID_RENAME_FILES
    DID_DELETE_FILES
    DID_CHANGE_CONFIGURATION
    FORMATTING

  FileAccessQuery* = object
    # id*: uint
    case kind*: FileAccessQueryKind
    of FileAccessQueryKind.DID_OPEN:
      didOpen*: DidOpenTextDocumentParams
    of FileAccessQueryKind.DID_CHANGE:
      didChange*: DidChangeTextDocumentParams
    of FileAccessQueryKind.DID_SAVE:
      didSave*: DidSaveTextDocumentParams
    of FileAccessQueryKind.DID_CLOSE:
      didClose*: DidCloseTextDocumentParams
    of FileAccessQueryKind.WILL_SAVE_WAIT_UNTIL:
      willSave*: WillSaveTextDocumentParams
      willSaveResponse*: Future[seq[TextEdit]]
    of FileAccessQueryKind.DID_RENAME_FILES:
      renameFiles*: RenameFilesParams
    of FileAccessQueryKind.DID_DELETE_FILES:
      deleteFiles*: DeleteFilesParams
    of FileAccessQueryKind.DID_CHANGE_CONFIGURATION:
      didChangeConfiguration*: JsonNode
    of FileAccessQueryKind.FORMATTING:
      formating*: DocumentFormattingParams
      formattingResponse*: Future[seq[TextEdit]]

# === LANGUAGE SERVER QUERIES ===
type
  LangserverQueryKind* {.pure.} = enum
    NIMSUGGEST    ## Route to a per-slot queryMailbox via routeQuery.
    FILE_ACCESS   ## Execute a file operation (open/change/save/close/rename/delete).

  LangserverQuery* = object
    case kind*: LangserverQueryKind
    of LangserverQueryKind.NIMSUGGEST:
      nimsuggest*: NimsuggestQuery
    of LangserverQueryKind.FILE_ACCESS:
      fileAccess*: FileAccessQuery
