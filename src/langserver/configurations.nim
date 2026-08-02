import std/[json, options]
import chronos
import chronicles

import ../protocol/types
import ./[langserver_types, configuration_types, constants]
import ../nimsuggest/nimsuggest

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

proc getWorkspaceConfiguration*(
    ls: LanguageServer
): Future[NlsConfig] {.async: (raises: []).} =
  try:
    #this is the root of a lot a problems as there are multiple race conditions here.
    #since most request doenst really rely on the configuration, we can just go ahead and 
    #return a default one until we have the right one. 
    #TODO review and handle project specific confs when received instead of reliying in this func
    if ls.workspaceConfiguration.finished:
      return parseWorkspaceConfiguration(ls.workspaceConfiguration.read)
    return NlsConfig()
  except CatchableError as ex:
    error "Failed to get workspace configuration", error = ex.msg
    writeStackTrace(ex)

proc getAndWaitForWorkspaceConfiguration*(
    ls: LanguageServer
): Future[NlsConfig] {.async.} =
  try:
    let conf = await ls.workspaceConfiguration
    return parseWorkspaceConfiguration(conf)
  except CatchableError as ex:
    error "Failed to get workspace configuration", error = ex.msg
    writeStackTrace(ex)


proc waitForWorkspaceConfiguration*(ls: LanguageServer): Future[NlsConfig] {.async.} =
  ## Waits for workspace configuration with a 30-second fallback to defaults.
  ## Safe to call from any async context; idempotent once config has arrived.
  ## Polls rather than awaiting the shared future directly to avoid cancelling it.
  if ls.workspaceConfiguration.finished:
    return await ls.getWorkspaceConfiguration()
  debug "Waiting for workspace configuration from client"
  var elapsed = 0
  while not ls.workspaceConfiguration.finished and elapsed < CONFIG_WAIT_TIMEOUT_MS:
    await sleepAsync(CONFIG_WAIT_POLL_MS)
    elapsed += CONFIG_WAIT_POLL_MS
  if ls.workspaceConfiguration.finished:
    debug "Workspace configuration received"
  else:
    warn "Workspace configuration not received within timeout, proceeding with defaults"
  return await ls.getWorkspaceConfiguration()


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

proc supportsConfigurationRequest(ls: LanguageServer): bool =
  ls.lspClientCapabilities.workspace.isSome and
    ls.lspClientCapabilities.workspace.get.configuration.get(false)

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
    ls.didChangeConfigurationRegistrationRequest =
      ls.call("client/registerCapability", %registrationParams)
    ls.didChangeConfigurationRegistrationRequest.addCallback do(res: Future[JsonNode]) {.
      gcsafe
    .}:
      debug "Got response for the didChangeConfiguration registration:",
        res = res.read()

proc handleConfigurationChanges*(
    ls: LanguageServer, oldConfiguration, newConfiguration: NlsConfig
) =
  if ls.lspClientCapabilities.workspace.isSome and
      ls.lspClientCapabilities.workspace.get.inlayHint.isSome and
      ls.lspClientCapabilities.workspace.get.inlayHint.get.refreshSupport.get(false) and
      not inlayHintsConfigurationEquals(oldConfiguration, newConfiguration):
    # toggling the exception hints triggers a full nimsuggest restart, since they are controlled by a nimsuggest command line option
    #   --exceptionInlayHints:on|off
    if not inlayExceptionHintsConfigurationEquals(oldConfiguration, newConfiguration):
      ls.restartAllNimsuggestInstances
    debug "Sending inlayHint refresh"
    ls.inlayHintsRefreshRequest = ls.call("workspace/inlayHint/refresh", newJNull())

proc maybeRequestConfigurationFromClient*(ls: LanguageServer) =
  if ls.supportsConfigurationRequest:
    debug "Requesting configuration from the client"
    let configurationParams = ConfigurationParams %* {"items": [{"section": "nim"}]}

    ls.prevWorkspaceConfiguration = ls.workspaceConfiguration

    ls.workspaceConfiguration = ls.call("workspace/configuration", %configurationParams)
    ls.workspaceConfiguration.addCallback do(futConfiguration: Future[JsonNode]):
      if futConfiguration.error.isNil:
        debug "Received the following configuration",
          configuration = futConfiguration.read()
        if not isNil(ls.prevWorkspaceConfiguration) and
            ls.prevWorkspaceConfiguration.finished:
          let
            oldConfiguration =
              parseWorkspaceConfiguration(ls.prevWorkspaceConfiguration.read)
            newConfiguration = parseWorkspaceConfiguration(futConfiguration.read)
          handleConfigurationChanges(ls, oldConfiguration, newConfiguration)
  else:
    debug "Client does not support workspace/configuration"
    ls.workspaceConfiguration.complete(newJArray())

proc requiresDynamicRegistrationForDidChangeConfiguration(ls: LanguageServer): bool =
  ls.lspClientCapabilities.workspace.isSome and
    ls.lspClientCapabilities.workspace.get.didChangeConfiguration.isSome and
    ls.lspClientCapabilities.workspace.get.didChangeConfiguration.get.dynamicRegistration.get(
      false
    )
