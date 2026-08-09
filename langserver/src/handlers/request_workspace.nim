import std/[json, sequtils, strformat, sets, sugar]
import chronos
import chronicles
import ../protocol/types
import ../configurations/constants
import ../langserver/[langserver_types, langserver, utils, checking]
import ../nimsuggest/[nimsuggest_types, nimsuggest_slots]
import ../utils/process_utils
import ../utils/utils as globalUtils
import ./[queries_nimsuggest, request_text_document]

# === workspace/executeCommand ===
proc executeCommand*(
  ls: LanguageServer, params: ExecuteCommandParams
): Future[JsonNode] {.async.} =
  let projectFile = FilePath(params.arguments[0].getStr)
  case params.command
  of RESTART_COMMAND:
    debug "Restarting nimsuggest", projectFile = projectFile
    if ls.pool != nil and projectFile in ls.pool.slots:
      let slot = ls.pool.slots[projectFile]
      slot.crashedUris.clear()
      discard await execStop(slot, ls.pool)
      traceAsyncErrors execSpawn(slot, ls.pool, projectFile)
  of CHECK_PROJECT_COMMAND:
    debug "Checking project", projectFile = projectFile
    ls.checkProject(pathToUri(projectFile)).traceAsyncErrors
  of RECOMPILE_COMMAND:
    debug "Clean build", projectFile = projectFile
    if ls.pool != nil and projectFile in ls.pool.slots:
      let slot = ls.pool.slots[projectFile]
      if slot.isLive:
        let token = fmt "Compiling {projectFile}"
        ls.workDoneProgressCreate(token)
        ls.progress(token, "begin", fmt "Compiling project {projectFile}")
        discard await execStop(slot, ls.pool)
        traceAsyncErrors execSpawn(slot, ls.pool, projectFile)
        ls.progress(token, "end")
        ls.checkProject(pathToUri(projectFile)).traceAsyncErrors

  result = newJNull()

# === workspace/symbol ===
proc workspaceSymbol*(
  ls: LanguageServer, params: WorkspaceSymbolParams, id: int
): Future[seq[SymbolInformation]] {.async.} =
  # Route through any live slot's queryMailbox.
  if ls.pool == nil:
    return @[]
  var liveUri = FileUri("")
  for slot in ls.pool.slots.values:
    if slot.isLive and slot.ownedUris.len > 0:
      liveUri = slot.ownedUris.toSeq[0]
      break
  if string(liveUri) == "":
    return @[]
  let q = ls.initNimsuggestFileQuery(id, liveUri, NimsuggestQueryKind.WORKSPACE_SYMBOLS)
  let symbols = await ls.addQueryToQueue(q)
  result = symbols.map(x => x.toUtf16Pos(ls).toSymbolInformation)
