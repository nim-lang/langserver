import ./[file_access_types]
import ../protocol/types

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

  FileAccessQuery* = object
    id*: uint
    case kind*: FileAccessQueryKind
    of DID_OPEN:
      didOpen*: DidOpenTextDocumentParams
    of DID_CHANGE:
      didChange*: DidChangeTextDocumentParams
    of DID_SAVE:
      didSave*: DidSaveTextDocumentParams
    of DID_CLOSE:
      didClose*: DidCloseTextDocumentParams
    of WILL_SAVE_WAIT_UNTIL:
      willSaveWaitUntil*: WillSaveTextDocumentParams
    of DID_RENAME_FILES:
      renameFiles*: RenameFilesParams
    of DID_DELETE_FILES:
      deleteFiles*: DeleteFilesParams
    of DID_CHANGE_CONFIGURATION:
      discard  # params not needed; server re-requests config from client

# === FILE ACCESS QUERIES ===
proc initDidOpenQuery*(
  ls: LanguageServer,
  params: DidOpenTextDocumentParams,
  id: int
): FileAccessQuery =
  return FileAccessQuery(
    id: id.uint,
    kind: FileAccessQueryKind.DID_OPEN,
    didOpen: params
  )

proc initDidChangeQuery*(
  ls: LanguageServer,
  params: DidChangeTextDocumentParams,
  id: int
): FileAccessQuery =
  return FileAccessQuery(
    id: id.uint,
    kind: FileAccessQueryKind.DID_CHANGE,
    didChange: params
  )

proc initDidSaveQuery*(
  ls: LanguageServer,
  params: DidSaveTextDocumentParams,
  id: int
): FileAccessQuery =
  return FileAccessQuery(
    id: id.uint,
    kind: FileAccessQueryKind.DID_SAVE,
    didSave: params
  )

proc initDidCloseQuery*(
  ls: LanguageServer,
  params: DidCloseTextDocumentParams,
  id: int
): FileAccessQuery =
  return FileAccessQuery(
    id: id.uint,
    kind: FileAccessQueryKind.DID_CLOSE,
    didClose: params
  )

proc initWillSaveWaitUntilQuery*(
  ls: LanguageServer,
  params: WillSaveTextDocumentParams,
  id: int
): FileAccessQuery =
  return FileAccessQuery(
    id: id.uint,
    kind: FileAccessQueryKind.WILL_SAVE_WAIT_UNTIL,
    willSaveWaitUntil: params
  )

proc initDidRenameFilesQuery*(
  ls: LanguageServer,
  params: RenameFilesParams,
  id: int
): FileAccessQuery =
  return FileAccessQuery(
    id: id.uint,
    kind: FileAccessQueryKind.DID_RENAME_FILES,
    renameFiles: params
  )

proc initDidDeleteFilesQuery*(
  ls: LanguageServer,
  params: DeleteFilesParams,
  id: int
): FileAccessQuery =
  return FileAccessQuery(
    id: id.uint,
    kind: FileAccessQueryKind.DID_DELETE_FILES,
    deleteFiles: params
  )

proc initDidChangeConfigurationQuery*(
  ls: LanguageServer,
  id: int
): FileAccessQuery =
  return FileAccessQuery(
    id: id.uint,
    kind: FileAccessQueryKind.DID_CHANGE_CONFIGURATION
  )

# proc runFileAccessQuery*(
#   ls: LanguageServer, query: FileAccessQuery
# ) = 
#   case query.kind
#   of DID_CHANGE:
#     let params: DidChangeTextDocumentParams = query.didChange
    
#   of DID_SAVE:
#     let params: DidSaveTextDocumentParams = query.didSave
#   of DID_CLOSE:
#     let params: DidCloseTextDocumentParams = query.didClose
#   of DID_OPEN:
#     let params: DidOpenTextDocumentParams = query.didOpen
#   of DID_RENAME_FILES:
#     let params: RenameFilesParams = query.renameFiles
#   of DID_DELETE_FILES:
#     let params: DeleteFilesParams = query.deleteFiles
#   of DID_CHANGE_CONFIGURATION:
#     discard  # params not needed; server re-requests config from client
#   of WILL_SAVE_WAIT_UNTIL:
#     let params: WillSaveTextDocumentParams = query.willSave
#     # Note this returns: seq[TextEdit]