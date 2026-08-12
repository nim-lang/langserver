import std/[options, os, times, strformat]
import chronos
import chronos/asyncproc
import stew/byteutils
import chronicles
import ../protocol/[enums, types]
import ../langserver/[langserver_types, langserver, langserver_utils, langserver_messaging]

# === textDocument/formatting ===
proc format*(
  ls: LanguageServer, nphPath: string, uri: FileUri
): Future[Option[TextEdit]] {.async.} =
  let filePath = ls.uriStorageLocation(uri)
  if not fileExists(string(filePath)):
    warn "File doesn't exist ", filePath = filePath, uri = uri
    return none(TextEdit)

  debug "nph starts", nphPath = nphPath, filePath = filePath
  let process = await startProcess(
    nphPath,
    arguments = @[string(filePath)],
    options = {UsePath},
    stderrHandle = AsyncProcess.Pipe,
  )
  let res = await process.waitForExit(InfiniteDuration)
  if res != 0:
    let err = string.fromBytes(process.stderrStream.read().await)
    error "There was an error trying to format the document. ", err = err
    ls.showMessage(&"Error formating {uri}:{err}", MessageType.Error)
    return none(TextEdit)

  #if enough time has passed since last modification, we skip the formatting:
  let lastModified = getLastModificationTime(string(filePath))
  let timeSinceLastModified = getTime() - lastModified
  let cond = timeSinceLastModified >= initDuration(seconds = 2)

  if timeSinceLastModified >= initDuration(seconds = 2):
    error "Skipping formatting because the file was modifyed long ago"
    return none(TextEdit)

  let formattedText = readFile(string(filePath))
  if formattedText.len < 2:
    error "Failed to format document", uri = uri
    return none(TextEdit)

  let fullRange = Range(
    start: Position(line: 0, character: 0),
    `end`: Position(line: uinteger.high, character: uinteger.high),
  )
  debug "Formatting document", uri = uri, formattedText = formattedText
  some TextEdit(range: fullRange, newText: formattedText)

# proc formatting*(
#   ls: LanguageServer, params: DocumentFormattingParams, id: int
# ): Future[seq[TextEdit]] {.async.} =
#   with (params.textDocument):
#     ls.addProjectFileToPendingRequest(id.uint, uri)
#     debug "Received Formatting request "
#     let formatTextEdit = await ls.format(getNphPath().get(), uri)
#     if formatTextEdit.isSome:
#       return @[formatTextEdit.get]
