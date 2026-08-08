import
  std/[
    jsconsole, strutils, jsfetch, asyncjs, sugar, sequtils, options, strformat, times,
    sets, tables
  ]
import platform/[vscodeApi, languageClientApi]

import
  platform/js/
    [jsNodeFs, jsNodePath, jsNodeCp, jsNodeUtil, jsNodeOs, jsNodeNet, jsPromise]
import nimUtils
from tools/nimBinTools import getNimbleExecPath, getBinPath, execNimbleCmd
import spec

type LSPInstallPathKind = enum
  lspPathInvalid #Invalid path
  lspPathLocal #Default local nimble install
  lspPathGlobal #Global nimble install
  lspPathSetting #User defined path

const MinimalLSPVersion = (1, 0, 0)
const MinimalCapabilitiesLSPVersion = (1, 5, 2)

proc `$`(v: LSPVersion): string =
  &"v{v.major}.{v.minor}.{v.patch}"

proc `>`(v1, v2: LSPVersion): bool =
  if v1.major != v2.major:
    v1.major > v2.major
  elif v1.minor != v2.minor:
    v1.minor > v2.minor
  else:
    v1.patch > v2.patch

proc `==`(v1, v2: LSPVersion): bool =
  v1.major == v2.major and v1.minor == v2.minor and v1.patch == v2.patch

proc parseVersion(version: string): Option[LSPVersion] =
  #expected version = vMajor.Minor.Patch
  var ver = version.split(".")
  if ver.len != 3:
    return none(LSPVersion)
  ver[0] = ver[0].replace("v", "")
  var versions = newSeq[int]()
  for v in ver:
    try:
      versions.add(parseInt(v.strip()))
    except CatchableError:
      console.error("Error parsing version", v.cstring)
      console.error(getCurrentExceptionMsg().cstring)
      return none(LSPVersion)
  some (versions[0], versions[1], versions[2])

proc getLatestVersion(versions: seq[LSPVersion]): LSPVersion =
  if versions.len == 0:
    console.warn("No versions found")
    return MinimalLSPVersion
  result = versions[0]
  for v in versions:
    if v > result:
      result = v

proc isSomeSafe(self: Option[LSPVersion]): bool {.inline.} =
  #hack to fix https://github.com/nim-lang/vscode-nim/issues/47
  var wrap {.exportc.} = self
  var test {.importcpp: ("('has' in wrap)").}: bool
  if test:
    self.isSome()
  else:
    false

proc getLatestReleasedLspVersion(default: LSPVersion): Future[LSPVersion] {.async.} =
  type Tag = object of JsObject
    name: cstring

  proc toTags(obj: JsObject): seq[Tag] {.importjs: ("#").}
  let url = " https://api.github.com/repos/nim-lang/langserver/tags".cstring
  var failed = false
  let res = await fetch(url)
  .then(
    proc(res: Response): auto =
      failed = res.status != 200
      if failed: #It may fail due to the rate limit
        console.error("Nimlangserver request to GitHub failed", res.statusText)
      res.json()
  )
  .then((json: JsObject) => json)
  .catch(
    proc(err: Error): JsObject =
      console.error("Nimlangserver request to GitHub failed", err)
      failed = true
  )
  if failed:
    return default
  else:
    return res.toTags
      .mapIt(parseVersion($it.name))
      .filterIt(it.isSomeSafe)
      .mapIt(it.get())
      .getLatestVersion()

proc isValidLspPath(lspPath: cstring): bool =
  result = not lspPath.isNil and lspPath != "" and fs.existsSync(path.resolve(lspPath))
  if lspPath.isNil:
    console.log("lspPath is nil")
  else:
    console.log(fmt"isValidLspPath({lspPath}) = {result}".cstring)

proc getLocalLspDir(): cstring =
  #The lsp is installed inside the user directory because the user 
  #storage of the extension seems to be too long and the installation fails
  result = path.join(nodeOs.homedir, ".vscode-nim")
  if not fs.existsSync(result):
    fs.mkdirSync(result)

proc getLspPath(state: ExtensionState): (cstring, LSPInstallPathKind) =
  #[
    We first try to use the path from the nim.lsp.path setting.
    If path is not set, we try to use the local nimlangserver binary.
    If the local binary is not found, we try to use the global nimlangserver binary.
  ]#
  var lspPath = vscode.workspace.getConfiguration("nim").getStr("lsp.path")
  if lspPath.isValidLspPath:
    return (lspPath, lspPathSetting)
  var langserverExec: cstring = "nimlangserver"
  if process.platform == "win32":
    langserverExec.add ".cmd"
  lspPath = path.join(getLocalLspDir(), "nimbledeps", "bin", langserverExec)
  if isValidLspPath(lspPath):
    return (lspPath, lspPathLocal)
  lspPath = getBinPath("nimlangserver")
  if isValidLspPath(lspPath):
    return (lspPath, lspPathGlobal)
  return ("".cstring, lspPathInvalid)

proc startLanguageServer(tryInstall: bool, state: ExtensionState) {.async.}

proc installNimLangServer(state: ExtensionState, version: Option[LSPVersion]) =
  var installCmd = "install nimlangserver"
  if version.isSome:
    let v = version.get
    installCmd.add("@" & &"{v.major}.{v.minor}.{v.patch}")
  let args: seq[cstring] = @[installCmd.cstring, "--accept", "-l"]
  
  proc onClose (code: cint, signal: cstring): void =
    if code == 0:
      outputLine("Nimble install successfully")
      discard startLanguageServer(false, state)
      console.log(
        "Nimble install finished, validating by checking if nimlangserver is present."
      )
    else:
      outputLine("Nimble install failed.")
  
  execNimbleCmd(args, getLocalLspDir(), onClose)

proc notifyOrUpdateOnTheLSPVersion(current, latest: LSPVersion, state: ExtensionState) =
  if latest > current:
    let (_, lspKind) = getLspPath(state)
    if lspKind == lspPathLocal:
      installNimLangServer(state, some(latest))
      let msg =
        &"""
  There is a new Nim langserver version available ({latest}). 
  Proceding to update the local installation of the langserver."""
      vscode.window.showInformationMessage(msg.cstring)
    else:
      var msg =
        &"""
  There is a new Nim langserver version available ({latest}). 
  You can install it by running: nimble install nimlangserver"""
      vscode.window.showInformationMessage(msg.cstring)
  else:
    outputLine("Your lsp version is updated")

proc handleLspVersion(
    nimlangserver: cstring, latestVersion: LSPVersion, state: ExtensionState
) =
  var isDone = false
  var gotError: ExecError
  var gotStdout: cstring
  var gotStderr: cstring

  proc onExec(error: ExecError, stdout: cstring, stderr: cstring) =
    # showing VS code user dialog messages does not appear to work from within this callback function,
    # so we save what we've got here and show all messages in onLspTimeout()
    isDone = true
    gotError = error
    gotStdout = stdout
    gotStderr = stderr

  var process: ChildProcess
  proc onLspTimeout() =
    if isDone:
      let ver = parseVersion($gotStdout)
      if ver.isNone():
        console.error("Unexpected output from nimlangserver: ", gotStdout, gotStderr)
      else:
        state.lspVersion = ver.get()
        notifyOrUpdateOnTheLSPVersion(ver.get, latestVersion, state)
    else:
      #Running 0.2.0 kill the started nimlangserver process and notify the user is running an old version of the lsp
      kill(process)
      notifyOrUpdateOnTheLSPVersion(MinimalLSPVersion, latestVersion, state)

  global.setTimeout(onLspTimeout, 1000)
  process = cp.exec((nimlangserver & " --version"), ExecOptions(), onExec)

proc refreshNotifications*(
    self: NimLangServerStatusProvider, notifications: seq[Notification]
) =
  self.notifications = notifications
  self.emitter.fire(nil)
  
proc refreshLspStatus*(
    self: NimLangServerStatusProvider, lspStatus: NimLangServerStatus
) =
  # console.log(lspStatus)
  self.status = some(lspStatus)
  self.emitter.fire(nil)
  # console.log(lspStatus.projectErrors)
  ext.addExtensionCapabilities(lspStatus.extensionCapabilities)
  ext.onExtensionReady()


proc fetchListTests*(state: ExtensionState, params: ListTestsParams): Future[ListTestsResult] {.async.} =
  let client = state.client
  let response = await client.sendRequest("extension/listTests", params.toJs())
  console.log(response.jsonStringify())
  let test = response.jsonStringify().jsonParse(ListTestsResult)
  return test

proc requestRunTest*(state: ExtensionState, params: RunTestParams): Future[RunTestProjectResult] {.async.} =
  let client = state.client
  let response = await client.sendRequest("extension/runTests", params.toJs())
  console.log(response.jsonStringify())
  let test = response.jsonStringify().jsonParse(RunTestProjectResult)
  return test

proc requestCancelTest*(state: ExtensionState): Future[CancelTestResult] {.async.} =
  let client = state.client
  let response = await client.sendRequest("extension/cancelTest", ().toJs())
  console.log(response.jsonStringify())
  let test = response.jsonStringify().jsonParse(CancelTestResult)
  return test

proc startClientSocket(portFut: Future[int]): proc(): Future[ServerOptions] {.async.} =
  return proc(): auto {.async.} =
    let port = await portFut
    let socket = net.createConnection(
      port.cint,
      "localhost",
      proc(): void =
        discard,
    )
    var streamInfo = newJsObject()
    streamInfo.reader = socket
    streamInfo.writer = socket
    let serverOptions = cast[ServerOptions](streamInfo)
    return promiseResolve(serverOptions)

proc startSocket(
    nimlangserver: cstring, state: ExtensionState
): proc(): Future[ServerOptions] =
  let config = vscode.workspace.getConfiguration("nim")
  let port = config.getInt("lspPort").int
  if port != 0:
    #the user specified a port so we dont need to start the server process. It's assumed is already running
    return startClientSocket(promiseResolve(port))
  let process = cp.exec((nimlangserver & " --socket"), ExecOptions(), nil)
  let portPromise = newPromise(
    proc(resolve: proc(port: int), reject: proc(reasons: JsObject)) =
      process.stdout.onData(
        proc(data: Buffer) =
          let msg = $data.toString()
          if msg.startsWith("port="):
            try:
              let port = parseInt(msg.subStr(5).strip)
              console.log ("nimlangserver socket listening at " & $port).cstring
              resolve(port)
            except ValueError as ex:
              console.error (
                "An error ocurred trying to parse the port " & msg.substr(5) & ex.msg
              ).cstring
          state.lspChannel.appendLine msg.cstring
      )
      #StdError is directed to the output of the lsp which is the same as the stdio version does
      process.stderr.onData(
        (data: Buffer) => state.lspChannel.appendLine(data.toString())
      )
  )
  startClientSocket(portPromise)

proc refreshNimbleTasks*() {.async.} =
  ext.nimbleTasks = await fetchLsp[seq[NimbleTask]](ext, "extension/tasks")

proc next_provideInlayHints(self: JsObject, document: JsObject, viewPort: JsObject, token: JsObject): Promise[JsObject] {.importjs: "#(@)".}
proc provideInlayHints(document: JsObject, viewPort: JsObject, token: JsObject, next: JsObject): Promise[seq[InlayHint]] {.async.}=
  var hintsToReturn = newSeq[InlayHint]()
  let jsInlayHints = next_provideInlayHints(next, document, viewPort, token).await
  let decorationType: VscodeTextEditorDecorationType = vscode.window.createTextEditorDecorationType(
    VscodeDecorationRenderOptions(
      textDecoration: "underline #0CAFFF"
    )
  )
  let doc = document.to(VscodeTextDocument)
  let uri = doc.fileName  
  if uri in ext.propagatedDecorations:
    for decoration in ext.propagatedDecorations[uri]:
      decoration.dispose()
  
  if jsInlayHints.isNull or jsInlayHints.isUndefined:
    return hintsToReturn

  let inlayHints = jsInlayHints.to(seq[InlayHint])

  var decorationRanges: seq[VscodeDecorationOptions] = @[]
  let propagatedExceptionSymbol = vscode.workspace.getConfiguration("nim").getStr("inlayHints.exceptionHints.hintStringLeft")
  for hint in inlayHints:
    if hint.label == propagatedExceptionSymbol:
      # console.log("🔔 found. Skipping", hint)
      let wordRange: VscodeRange = doc.getWordRangeAtPosition(hint.position)
      let pos: VscodePosition = hint.position      
      decorationRanges.add(VscodeDecorationOptions(
        range: wordRange,
        hoverMessage: hint.tooltip
      ))
      if uri notin ext.propagatedDecorations:
        ext.propagatedDecorations[uri] = newSeq[VscodeTextEditorDecorationType]()
      ext.propagatedDecorations[uri].add(decorationType)
    else:
      hintsToReturn.add(hint)
  
  if decorationRanges.len > 0:
    let editor = vscode.window.activeTextEditor
    if not editor.isNil:
      editor.setDecorations(decorationType, decorationRanges)
  
  return hintsToReturn

proc startLanguageServer(tryInstall: bool, state: ExtensionState) {.async.} =
  let (rawPath, lspPathKind) = getLspPath(state)
  if lspPathKind == lspPathInvalid:
    console.log("nimlangserver not found on path")
    if tryInstall and not state.installPerformed:
      let command = getNimbleExecPath() & " install nimlangserver --accept -l"

      vscode.window
      .showInformationMessage(
        cstring(
          fmt "Unable to find nimlangserver. Do you want me to attempt to install it via '{command}'?"
        ),
        VscodeMessageOptions(detail: cstring(""), modal: false),
        VscodeMessageItem(title: cstring("Yes"), isCloseAffordance: false),
        VscodeMessageItem(title: cstring("No"), isCloseAffordance: true),
      )
      .then(
        onfulfilled = proc(value: JsRoot): JsRoot =
          if value.JsObject.to(VscodeMessageItem).title == "Yes":
            if not state.installPerformed:
              state.installPerformed = true
              vscode.window.showInformationMessage(
                cstring(fmt "Trying to install nimlangserver via '{command}'")
              )
              installNimLangServer(state, none(LSPVersion))
          value,
        onrejected = proc(reason: JsRoot): JsRoot =
          reason,
      )
    else:
      let cantInstallInfoMesssage: cstring =
        "Unable to find/install `nimlangserver`. You can attempt to install it by running `nimble install nimlangserver` or downloading the binaries from https://github.com/nim-lang/langserver/releases."
      vscode.window.showInformationMessage(cantInstallInfoMesssage)
  else:
    let nimlangserver = path.resolve(rawPath).quoteOnlyWin()
    outputLine(fmt"nimlangserver found: {nimlangserver}".cstring)
    outputLine("Starting nimlangserver.")
    let latestVersion = await getLatestReleasedLspVersion(MinimalLSPVersion)
    handleLspVersion(nimlangserver, latestVersion, state)

    let
      serverOptions = ServerOptions{
        run: Executable{
          command: nimlangserver,
          transport: TransportKind.stdio,
          options: ExecutableOptions(shell: true),
        },
        debug: Executable{
          command: nimlangserver,
          transport: TransportKind.stdio,
          options: ExecutableOptions(shell: true),
        },
      }
      clientOptions = LanguageClientOptions{
        documentSelector:
          @[
            DocumentFilter(scheme: cstring("file"), language: cstring("nim")),
            DocumentFilter(scheme: cstring("file"), language: cstring("nimble")),
            DocumentFilter(scheme: cstring("file"), language: cstring("nims")),
          ],
        outputChannel: state.lspChannel,
        middleware: VscodeLanguageClientMiddleware(provideInlayHints: provideInlayHints),
      }
    let config = vscode.workspace.getConfiguration("nim")
    let transportMode = config.getStr("transportMode")
    case transportMode
    of "socket":
      state.client = vscodeLanguageClient.newLanguageClient(
        cstring("nimlangserver"),
        cstring("Nim Language Server"),
        startSocket(nimlangserver, state),
        clientOptions,
      )
    else:
      state.client = vscodeLanguageClient.newLanguageClient(
        cstring("nimlangserver"),
        cstring("Nim Language Server"),
        serverOptions,
        clientOptions,
      )

    await state.client.start()

    state.client.onNotification(
      "extension/statusUpdate",
      proc(params: JsObject) =
        if params.projectErrors.isUndefined:
          params.projectErrors = newSeq[ProjectError]()
        if params.pendingRequests.isUndefined:
          params.pendingRequests = newSeq[PendingRequestStatus]()
        if params.extensionCapabilities.isUndefined:
          params.extensionCapabilities = newSeq[cstring]()
      
        let lspStatus = jsonStringify(params).jsonParse(NimLangServerStatus)
        # outputLine("Received status update " & jsonStringify(params))
        refreshLspStatus(state.statusProvider, lspStatus),
    )

    type
      Message = object of JsObject
        message: cstring
        `type`: MessageType

      MessageType {.pure.} = enum
        Error = 1
        Warning = 2
        Info = 3
        Log = 4
        Debug = 5

    func messageTypToStr(typ: MessageType): cstring =
      case typ
      of MessageType.Error: "error"
      of Warning: "warning"
      else: "info"

    state.client.onNotification(
      "window/showMessage",
      proc(params: JsObject) =
        let message = jsonStringify(params).jsonParse(Message)
        inc state.statusProvider.lastId
        let id = $state.statusProvider.lastId
        let notification = Notification(
          message: message.message,
          kind: messageTypToStr(message.`type`),
          id: id.cstring,
          date: now(),
        )
        let nots = state.statusProvider.notifications & @[notification]
        refreshNotifications(state.statusProvider, nots),
    )

    await refreshNimbleTasks()

    let expiredTime = state.config.getInt("notificationTimeout")
    if expiredTime > 0:
      global.setInterval(
        proc() =
          let notifications = state.statusProvider.notifications.filterIt(
            it.date > now() - expiredTime.seconds
          )
          refreshNotifications(state.statusProvider, notifications),
        1000, #refresh time
      )

    outputLine("Nim Language Server started")

export startLanguageServer

proc stopLanguageServer(state: ExtensionState) {.async.} =
  await state.client.stop()

export stopLanguageServer
