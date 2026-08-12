import std/[options, json, os]
import chronos
import chronicles
import ../protocol/[types, enums]
import ../utils/asyncprocmonitor
import ../nimsuggest/nimsuggest
import ../langserver/[langserver_types]

proc getNphPath*(): Option[string] =
  let path = findExe "nph"
  if path == "":
    none(string)
  else:
    some path

# === initialize ===
proc initialize*(
  p: tuple[ls: LanguageServer, onExit: OnExitCallback], params: LspInitializeParams
): Future[LspInitializeResult] {.async.} =
  proc onClientProcessExitAsync(): Future[void] {.async.} =
    debug "onClientProcessExitAsync"
    await p.ls.pool.stopNimsuggestProcesses()
    await p.onExit()

  proc onClientProcessExit() {.closure, gcsafe.} =
    try:
      debug "onClientProcessExit"
      waitFor onClientProcessExitAsync()
    except Exception:
      error "Error in onClientProcessExit ", msg = getCurrentExceptionMsg()

  debug "Initialize received..."
  if params.processId.isSome:
    let pid = params.processId.get
    if pid.kind == JInt:
      debug "Registering monitor for process ", pid = pid.num
      var pidInt = int(pid.num)
      if p.ls.cmdLineClientProcessId.isSome:
        if p.ls.cmdLineClientProcessId.get == pidInt:
          debug "Process ID already specified in command line, no need to register monitor again"
        else:
          debug "Warning! Client Process ID in initialize request differs from the one, specified in the command line. This means the client violates the LSP spec!"
          debug "Will monitor both process IDs..."
          hookAsyncProcMonitor(pidInt, onClientProcessExit)
      else:
        hookAsyncProcMonitor(pidInt, onClientProcessExit)
  p.ls.capabilities.lspInitializeParams = params
  p.ls.capabilities.lspClientCapabilities = params.capabilities
  result = LspInitializeResult(
    capabilities: LspServerCapabilities(
      textDocumentSync: some(
        %TextDocumentSyncOptions(
          openClose: some(true),
          change: some(TextDocumentSyncKind.Full.int),
          willSave: some(false),
          willSaveWaitUntil: some(true),
          save: some(SaveOptions(includeText: some(true))),
        )
      ),
      hoverProvider: some(true),
      workspace: some(
        ServerCapabilities_workspace(
          workspaceFolders: some(WorkspaceFoldersServerCapabilities()),
          fileOperations: some(
            ServerCapabilities_workspace_fileOperations(
              didRename: some(
                FileOperationRegistrationOptions(
                  filters: @[
                    FileOperationFilter(
                      scheme: some("file"),
                      pattern: FileOperationPattern(glob: "**/*.nim"),
                    )
                  ]
                )
              ),
              didDelete: some(
                FileOperationRegistrationOptions(
                  filters: @[
                    FileOperationFilter(
                      scheme: some("file"),
                      pattern: FileOperationPattern(glob: "**/*.nim"),
                    )
                  ]
                )
              ),
            )
          ),
        )
      ),
      completionProvider:
        CompletionOptions(triggerCharacters: some(@["."]), resolveProvider: some(false)),
      signatureHelpProvider: SignatureHelpOptions(triggerCharacters: some(@["(", ","])),
      definitionProvider: some(true),
      declarationProvider: some(true),
      typeDefinitionProvider: some(true),
      referencesProvider: some(true),
      documentHighlightProvider: some(true),
      workspaceSymbolProvider: some(true),
      executeCommandProvider: some(
        ExecuteCommandOptions(
          commands: some(@[
            "nimtortoise.recompile",
            "nimtortoise.restart",
            "nimtortoise.checkProject"
          ])
        )
      ),
      inlayHintProvider: some(InlayHintOptions(resolveProvider: some(false))),
      documentSymbolProvider: some(true),
      codeActionProvider: some(true),
      documentFormattingProvider: some(getNphPath().isSome),
    )
  )
  # Support rename by default, but check if we can also support prepare
  result.capabilities.renameProvider = %true
  if params.capabilities.textDocument.isSome:
    let docCaps = params.capabilities.textDocument.unsafeGet()
    # Check if the client support prepareRename
    #TODO do the test on the action
    if docCaps.rename.isSome and docCaps.rename.get().prepareSupport.get(false):
      result.capabilities.renameProvider = %*{"prepareProvider": true}

  debug "Initialize completed. Nimsuggest instances will start after configuration arrives."

  let ls = p.ls
  ls.capabilities.lspServerCapabilities = result.capabilities

# === shutdown ===
proc shutdown*(ls: LanguageServer, input: JsonNode): Future[JsonNode] {.async.} =
  debug "Shutting down"
  await ls.pool.stopNimsuggestProcesses()
  ls.isShutdown = true
  # let id = input{"id"}.extractId
  result = newJNull()
  trace "Shutdown complete"

# === exit ===
proc exit*(
  p: tuple[ls: LanguageServer, onExit: OnExitCallback], _: JsonNode
): Future[JsonNode] {.async.} =
  if not p.ls.isShutdown:
    debug "Received an exit request without prior shutdown request"
    await p.ls.pool.stopNimsuggestProcesses()
  debug "Quitting process"
  result = newJNull()
  await p.onExit()
