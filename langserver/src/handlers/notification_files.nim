import std/json
import chronos
import chronicles
import ../protocol/types
import ../langserver/langserver_types
import ./[queries_file_access]

# === textDocument/didChange ===
proc didChange*(
  ls: LanguageServer, params: DidChangeTextDocumentParams
): Future[void] {.async.} =
  ls.addQueryToQueue(initDidChangeQuery(params))
  return 

# === textDocument/willSaveWaitUntil ===
proc willSaveWaitUntil*(
  ls: LanguageServer, params: WillSaveTextDocumentParams
): Future[seq[TextEdit]] {.async.} =
  debug "Received willSaveWaitUntil request"
  return await ls.addWillSaveQueryToQueue(params)

# === textDocument/didSave ===
proc didSave*(
  ls: LanguageServer, params: DidSaveTextDocumentParams
): Future[void] {.async.} =
  ls.addQueryToQueue(initDidSaveQuery(params))
  return 

# === textDocument/didClose ===
proc didClose*(
  ls: LanguageServer, params: DidCloseTextDocumentParams
): Future[void] {.async.} =
  ls.addQueryToQueue(initDidCloseQuery(params))
  return 

# === textDocument/didOpen ===
proc didOpen*(
  ls: LanguageServer, params: DidOpenTextDocumentParams
): Future[void] {.async.} =
  ls.addQueryToQueue(initDidOpenQuery(params))
  return 

# === workspace/didRenameFiles ===
proc didRenameFiles*(
  ls: LanguageServer, params: RenameFilesParams
): Future[void] {.async.} =
  ls.addQueryToQueue(initDidRenameFilesQuery(params))
  return 

# === workspace/didDeleteFiles ===
proc didDeleteFiles*(
  ls: LanguageServer, params: DeleteFilesParams
): Future[void] {.async.} =
  ls.addQueryToQueue(initDidDeleteFilesQuery(params))
  return 

# === workspace/didChangeConfiguration ===
proc didChangeConfiguration*(
  ls: LanguageServer, conf: JsonNode
): Future[void] {.async.} =
  debug "Changed configuration: ", conf = conf
  ls.addQueryToQueue(initDidChangeConfigurationQuery(conf))
