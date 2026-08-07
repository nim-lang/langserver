import std/json
import chronos
import ../protocol/types
import ../langserver/[query_types, langserver_types]

proc initDidOpenQuery*(params: DidOpenTextDocumentParams): FileAccessQuery =
  FileAccessQuery(kind: FileAccessQueryKind.DID_OPEN, didOpen: params)

proc initDidChangeQuery*(params: DidChangeTextDocumentParams): FileAccessQuery =
  FileAccessQuery(kind: FileAccessQueryKind.DID_CHANGE, didChange: params)

proc initDidSaveQuery*(params: DidSaveTextDocumentParams): FileAccessQuery =
  FileAccessQuery(kind: FileAccessQueryKind.DID_SAVE, didSave: params)

proc initDidCloseQuery*(params: DidCloseTextDocumentParams): FileAccessQuery =
  FileAccessQuery(kind: FileAccessQueryKind.DID_CLOSE, didClose: params)

proc initDidRenameFilesQuery*(params: RenameFilesParams): FileAccessQuery =
  FileAccessQuery(kind: FileAccessQueryKind.DID_RENAME_FILES, renameFiles: params)

proc initDidDeleteFilesQuery*(params: DeleteFilesParams): FileAccessQuery =
  FileAccessQuery(kind: FileAccessQueryKind.DID_DELETE_FILES, deleteFiles: params)

proc initDidChangeConfigurationQuery*(conf: JsonNode): FileAccessQuery =
  FileAccessQuery(
    kind: FileAccessQueryKind.DID_CHANGE_CONFIGURATION,
    didChangeConfiguration: conf
  )

# === Queues ===
proc addQueryToQueue*(ls: LanguageServer, q: FileAccessQuery) =
  ls.langserverQueue.addLastNoWait(LangserverQuery(kind: LangserverQueryKind.FILE_ACCESS, fileAccess: q))

proc addWillSaveQueryToQueue*(
  ls: LanguageServer, 
  params: WillSaveTextDocumentParams,
): Future[seq[TextEdit]] =

  let query = LangserverQuery(
    kind: LangserverQueryKind.FILE_ACCESS,
    fileAccess: FileAccessQuery(
      # id: id.uint,
      kind: FileAccessQueryKind.WILL_SAVE_WAIT_UNTIL,
      willSave: params,
      willSaveResponse: newFuture[seq[TextEdit]]("fileAccessQuery")
    )
  )
  ls.langserverQueue.addLastNoWait(query)
  return query.fileAccess.willSaveResponse

proc addFormattingQueryToQueue*(
  ls: LanguageServer, 
  params: DocumentFormattingParams,
): Future[seq[TextEdit]] =
  let query = LangserverQuery(
    kind: LangserverQueryKind.FILE_ACCESS,
    fileAccess: FileAccessQuery(
      kind: FileAccessQueryKind.FORMATTING,
      formatting: params,
      formattingResponse: newFuture[seq[TextEdit]]("fileAccessQuery")
    )
  )
  ls.langserverQueue.addLastNoWait(query)
  return query.fileAccess.formattingResponse

