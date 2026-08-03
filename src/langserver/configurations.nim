import std/[json, options]
import chronos
import chronicles

import ../protocol/types
import ./[langserver_types, configuration_types, constants, messaging_types]

func typeHintsEnabled*(cnf: NlsConfig): bool =
  result = true
  if cnf.inlayHints.isSome and cnf.inlayHints.get.typeHints.isSome and
      cnf.inlayHints.get.typeHints.get.enable.isSome:
    result = cnf.inlayHints.get.typeHints.get.enable.get

func exceptionHintsEnabled*(cnf: NlsConfig): bool =
  result = true
  if cnf.inlayHints.isSome and cnf.inlayHints.get.exceptionHints.isSome and
      cnf.inlayHints.get.exceptionHints.get.enable.isSome:
    result = cnf.inlayHints.get.exceptionHints.get.enable.get

func parameterHintsEnabled*(cnf: NlsConfig): bool =
  result = true
  if cnf.inlayHints.isSome and cnf.inlayHints.get.parameterHints.isSome and
      cnf.inlayHints.get.parameterHints.get.enable.isSome:
    result = cnf.inlayHints.get.parameterHints.get.enable.get

func inlayHintsEnabled*(cnf: NlsConfig): bool =
  typeHintsEnabled(cnf) or exceptionHintsEnabled(cnf) or parameterHintsEnabled(cnf)


proc parseWorkspaceConfiguration*(conf: JsonNode): NlsConfig =
  try:
    if conf.kind == JObject and conf["settings"].kind == JObject:
      return conf["settings"]["nim"].to(NlsConfig)
  except CatchableError:
    discard
  try:
    let nlsConfig: seq[NlsConfig] = (%conf).to(seq[NlsConfig])
    result =
      if nlsConfig.len > 0 and nlsConfig[0] != nil:
        nlsConfig[0]
      else:
        NlsConfig()
  except CatchableError:
    debug "Failed to parse the configuration.", error = getCurrentExceptionMsg()
    result = NlsConfig()

proc getWorkspaceConfiguration*(ls: LanguageServer): NlsConfig =
  ## Returns current config synchronously. Returns defaults if config not yet received.
  ls.configurations.currentConfig.get(NlsConfig())

proc getAndWaitForWorkspaceConfiguration*(
    ls: LanguageServer
): Future[NlsConfig] {.async.} =
  await ls.configurations.configReady.wait()
  return ls.getWorkspaceConfiguration()

proc waitForWorkspaceConfiguration*(ls: LanguageServer): Future[void] {.async.} =
  ## Waits until workspace configuration is available, with a 30-second timeout.
  ## Uses polling (not raw AsyncEvent.wait) so cancelling this future does not
  ## cancel the shared configReady event, which would break other awaiters.
  if ls.configurations.currentConfig.isSome:
    return
  debug "Waiting for workspace configuration from client"
  var elapsed = 0
  while ls.configurations.currentConfig.isNone and elapsed < CONFIG_WAIT_TIMEOUT_MS:
    await sleepAsync(CONFIG_WAIT_POLL_MS.milliseconds)
    inc elapsed, CONFIG_WAIT_POLL_MS
  if ls.configurations.currentConfig.isNone:
    warn "Workspace configuration not received within timeout; proceeding with defaults"


proc inlayExceptionHintsConfigurationEquals*(a, b: NlsInlayHintsConfig): bool =
  if a.exceptionHints.isSome and b.exceptionHints.isSome:
    let
      ae = a.exceptionHints.get
      be = b.exceptionHints.get
    result =
      (ae.enable == be.enable) and (ae.hintStringLeft == be.hintStringLeft) and
      (ae.hintStringRight == be.hintStringRight)
  else:
    result = a.exceptionHints.isSome == b.exceptionHints.isSome

proc inlayExceptionHintsConfigurationEquals*(a, b: NlsConfig): bool =
  if a.inlayHints.isSome and b.inlayHints.isSome:
    result = inlayExceptionHintsConfigurationEquals(a.inlayHints.get, b.inlayHints.get)
  else:
    result = a.inlayHints.isSome == b.inlayHints.isSome

proc inlayHintsConfigurationEquals*(a, b: NlsConfig): bool =
  proc inlayTypeHintsConfigurationEquals(a, b: NlsInlayHintsConfig): bool =
    if a.typeHints.isSome and b.typeHints.isSome:
      result = a.typeHints.get.enable == b.typeHints.get.enable
    else:
      result = a.typeHints.isSome == b.typeHints.isSome

  proc inlayHintsConfigurationEquals(a, b: NlsInlayHintsConfig): bool =
    result =
      inlayTypeHintsConfigurationEquals(a, b) and
      inlayExceptionHintsConfigurationEquals(a, b)

  if a.inlayHints.isSome and b.inlayHints.isSome:
    result = inlayHintsConfigurationEquals(a.inlayHints.get, b.inlayHints.get)
  else:
    result = a.inlayHints.isSome == b.inlayHints.isSome

proc supportsConfigurationRequest*(ls: LanguageServer): bool =
  ls.capabilities.serverMode == lsp and
    ls.capabilities.lspClientCapabilities.workspace.isSome and
    ls.capabilities.lspClientCapabilities.workspace.get.configuration.get(false)

proc requiresDynamicRegistrationForDidChangeConfiguration*(ls: LanguageServer): bool =
  ls.capabilities.serverMode == lsp and
    ls.capabilities.lspClientCapabilities.workspace.isSome and
    ls.capabilities.lspClientCapabilities.workspace.get.didChangeConfiguration.isSome and
    ls.capabilities.lspClientCapabilities.workspace.get.didChangeConfiguration.get.dynamicRegistration.get(
      false
    )

proc usePullConfigurationModel*(ls: LanguageServer): bool =
  ls.requiresDynamicRegistrationForDidChangeConfiguration and
    ls.supportsConfigurationRequest


proc maybeRegisterCapabilityDidChangeConfiguration*(ls: LanguageServer) =
  if ls.requiresDynamicRegistrationForDidChangeConfiguration:
    let registrationParams = RegistrationParams(
      registrations: some(
        @[
          Registration(
            id: "a4606617-82c1-4e22-83db-0095fecb1093",
            `method`: "workspace/didChangeConfiguration",
          )
        ]
      )
    )
    discard ls.call("client/registerCapability", %registrationParams)

proc receiveConfiguration(ls: LanguageServer, configFuture: Future[JsonNode]) {.async.} =
  try:
    let conf = await configFuture
    debug "Received the following configuration", configuration = conf
    let newConfiguration = parseWorkspaceConfiguration(conf)
    ls.configurations.currentConfig = some(newConfiguration)
    ls.configurations.configReady.fire()
  except CatchableError as ex:
    debug "Failed to receive workspace configuration", error = ex.msg

proc maybeRequestConfigurationFromClient*(ls: LanguageServer) =
  if ls.supportsConfigurationRequest:
    debug "Requesting configuration from the client"
    let configurationParams = %*{"items": [{"section": "nim"}]}
    let configFuture = ls.call("workspace/configuration", configurationParams)
    asyncSpawn ls.receiveConfiguration(configFuture)
  else:
    debug "Client does not support workspace/configuration"
    ls.configurations.currentConfig = some(NlsConfig())
    ls.configurations.configReady.fire()
