## This is the extension file that gets loaded by vscode

when not defined(js):
  {.error: "This module only works on the JavaScript platform".}

import platform/vscodeApi
import platform/js/[jsre, jsString, jsNodeFs, jsNodePath, jsNodeCp]
import std/[strformat, jsconsole, strutils, options, sugar, json]
from std/os import `/`
import state/state_types
import tools/nimUtils
import commands/compiler_commands
import commands/debug_commands
import commands/project_commands
import commands/file_commands
import commands/nimble_commands
import commands/test_commands
import language_server/language_server
import language_server/language_configuration
import status_panel/nimStatus
import status_panel/nimlspstatuspanel

var state: ExtensionState

proc showNimLangServerStatus() {.async.} =
  let lspStatus = await fetchLspStatus(state)
  refreshLspStatus(state.statusProvider, lspStatus)

proc activate*(ctx: VscodeExtensionContext): void {.async.} =
  var config = vscode.workspace.getConfiguration("nimTortoise")
  state = ExtensionState(
    ctx: ctx,
    config: config,
    channel: vscode.window.createOutputChannel("Nim"),
    lspChannel: vscode.window.createOutputChannel("Nim Lsp"),
  )
  nimUtils.ext = state

  vscode.commands.registerCommand("nimTortoise.run.file", runFile)
  vscode.commands.registerCommand("nimTortoise.debug.file", debugFile)
  vscode.commands.registerCommand(
    "nimTortoise.restartNimsuggest", () => onLspSuggest("restart", "current")
  )
  vscode.commands.registerCommand(
    "nimTortoise.execSelectionInTerminal", execSelectionInTerminal
  )
  vscode.commands.registerCommand(
    "nimTortoise.showNimLangServerStatus", showNimLangServerStatus
  )
  vscode.commands.registerCommand("nimTortoise.showNotification", onShowNotification)
  vscode.commands.registerCommand("nimTortoise.onDeleteNotification", onDeleteNotification)
  vscode.commands.registerCommand(
    "nimTortoise.onClearAllNotifications", onClearAllNotifications
  )
  vscode.commands.registerCommand("nimTortoise.onNimbleTask", onNimbleTask)
  vscode.commands.registerCommand("nimTortoise.onRefreshNimbleTasks", refreshNimbleTasks)
  vscode.commands.registerCommand("nimTortoise.onLspSuggest", onLspSuggest)
  vscode.commands.registerCommand("nimTortoise.checkProject", onCheckProject)
  vscode.commands.registerCommand("nimTortoise.openGeneratedFile", openGeneratedFile)
  vscode.commands.registerCommand("nimTortoise.refreshTests", refreshTests)

  processConfig(config)
  discard vscode.workspace.onDidChangeConfiguration(configUpdate)
  vscode.debug.onDidStartDebugSession(onStartDebugSession)

  setNimDir(state)
  await startLanguageServer(true, state)
  state.statusProvider = newNimLangServerStatusProvider()
  discard vscode.window.registerTreeDataProvider("nim", state.statusProvider)

  var languageConfig = initNimLanguageConfiguration()
  try:
    vscode.languages.setLanguageConfiguration(
      "nim", languageConfig
    )
  except:
    console.error(
      "language configuration failed to set",
      getCurrentException(),
      getCurrentExceptionMsg().cstring,
    )

  vscode.window.onDidChangeActiveTextEditor(showHideStatus, nil, ctx.subscriptions)

  initTerminalHandlers()

  console.log(
    fmt"""
        ExtensionContext:
        extensionPath:{ctx.extensionPath}
        storagePath:{ctx.storagePath}
        logPath:{ctx.logPath}
      """.cstring.strip()
  )
  activateEvalConsole()
  if not fs.existsSync(ctx.storagePath):
    fs.mkdirSync(ctx.storagePath)

  outputLine("[info] Extension Activated")
  showNimbleSetupDialog()

  let nimbleCodeLensProvider = newCodeLensProvider(provideNimbleTasksCodeLenses)
  ctx.subscriptions.add(
    vscode.languages.registerCodeLensProvider(
      VscodeDocumentFilter(language: "nimble", scheme: "file"),
      nimbleCodeLensProvider
    )
  )

  # Watch for .nimble files
  let nimbleWatcher = vscode.workspace.createFileSystemWatcher("**/*.nimble")
  nimbleWatcher.onDidChange(proc(uri: VscodeUri) =
    # console.log("*********nimbleWatcher.onDidChange called", uri)
    if uri.path == vscode.window.activeTextEditor.document.uri.path:
      discard refreshNimbleTasks()
    #TODO update tasks here
      # provideNimbleTasksDecorations(ctx, vscode.window.activeTextEditor.document)
  )
  ctx.subscriptions.add(nimbleWatcher)
  initializeTests(ctx, nimUtils.ext)

proc deactivate*(): void {.async.} =
  await stopLanguageServer(nimUtils.ext)

var module {.importc.}: JsObject
module.exports.activate = activate
module.exports.deactivate = deactivate
