# === workspace/executeCommand ===
proc executeCommand*(
    ls: LanguageServer, params: ExecuteCommandParams
): Future[JsonNode] {.async.} =
  let projectFile = params.arguments[0].getStr
  case params.command
  of RESTART_COMMAND:
    debug "Restarting nimsuggest", projectFile = projectFile
    if ls.pool != nil:
      let slotOpt = ls.pool.findSlot(projectFile)
      if slotOpt.isSome:
        let slot = slotOpt.get
        slot.crashedUris.clear()
        slot.send SlotCommand(
          kind: SlotCommandKind.RESTART,
          spawnProjectFile: projectFile,
          spawnTriggerUri: projectFile.pathToUri,
        )
  of CHECK_PROJECT_COMMAND:
    debug "Checking project", projectFile = projectFile
    ls.checkProject(projectFile.pathToUri).traceAsyncErrors
  of RECOMPILE_COMMAND:
    debug "Clean build", projectFile = projectFile
    if ls.pool != nil:
      let slotOpt = ls.pool.findSlot(projectFile)
      if slotOpt.isSome and slotOpt.get.isLive:
        let slot = slotOpt.get
        let token = fmt "Compiling {projectFile}"
        ls.workDoneProgressCreate(token)
        ls.progress(token, "begin", fmt "Compiling project {projectFile}")
        slot.send SlotCommand(kind: SlotCommandKind.RECOMPILE)
        ls.progress(token, "end")
        ls.checkProject(projectFile.pathToUri).traceAsyncErrors

  result = newJNull()

# === workspace/symbol ===
proc workspaceSymbol*(
    ls: LanguageServer, params: WorkspaceSymbolParams, id: int
): Future[seq[SymbolInformation]] {.async.} =
  # Route through any live slot's queryMailbox.
  if ls.pool == nil:
    return @[]
  var liveUri = ""
  for slot in ls.pool.slots.values:
    if slot.resolvedNs.isSome and slot.ownedUris.len > 0:
      liveUri = slot.ownedUris.toSeq[0]
      break
  if liveUri == "":
    return @[]
  let symbols = await ls.queryWorkspaceSymbols(liveUri, params.query)
  result = symbols.map(x => x.toUtf16Pos(ls).toSymbolInformation)
