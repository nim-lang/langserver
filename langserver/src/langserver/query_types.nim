import std/json
import chronos
import ../nimsuggest/nimsuggest_types
import ../protocol/types

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
      formatting*: DocumentFormattingParams
      formattingResponse*: Future[seq[TextEdit]]

# === LANGUAGE SERVER QUERIES ===
type
  LangserverQueryKind* {.pure.} = enum
    NIMSUGGEST    ## Route to a per-slot queryMailbox via routeQuery.
    FILE_ACCESS   ## Execute a file operation (open/change/save/close/rename/delete).

  LangserverQuery* = object
    case kind*: LangserverQueryKind
    of LangserverQueryKind.NIMSUGGEST:
      nimsuggest*: NimsuggestQuery[LspFilePosition]
    of LangserverQueryKind.FILE_ACCESS:
      fileAccess*: FileAccessQuery
