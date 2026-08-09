import std/[json, options]
import chronos
import chronicles
import ../protocol/types
import ../configurations/[configurations, configuration_types]
import ../configurations/constants
import ./[langserver_types]

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


proc waitForLsInitialized*(ls: LanguageServer): Future[void] {.async.} =
  ## Waits until initNimsuggestInstances has completed (config received, nimble dump
  ## done, entry-point slots spawned), with a 60-second timeout.
  ## Uses polling so a timeout does not cancel the shared lsInitialized future.
  if ls.lsInitialized.finished:
    return
  debug "DID_OPEN: waiting for ls initialization (initNimsuggestInstances not yet done)"
  var elapsed = 0
  while not ls.lsInitialized.finished and elapsed < 60_000:
    await sleepAsync(100.milliseconds)
    inc elapsed, 100
  if not ls.lsInitialized.finished:
    warn "initNimsuggestInstances did not complete within timeout; proceeding anyway"

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
    let configurationParams = %*{"items": [{"section": "nimTortoise"}, {"section": "nim"}]}
    let configFuture = ls.call("workspace/configuration", configurationParams)
    asyncSpawn ls.receiveConfiguration(configFuture)
  else:
    debug "Client does not support workspace/configuration"
    if ls.configurations.currentConfig.isNone:
      ls.configurations.currentConfig = some(NlsConfig())
    ls.configurations.configReady.fire()

