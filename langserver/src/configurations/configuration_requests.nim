import chronos
import chronicles
import ./[configuration_types, constants]

# proc receiveConfiguration*(ls: LanguageServer, configFuture: Future[JsonNode]) {.async.} =
#   try:
#     let conf = await configFuture
#     debug "Received the following configuration", configuration = conf
#     let newConfiguration = parseConfigurationResponse(conf)
#     ls.configurations.currentConfig = newConfiguration # TODO
#     ls.configurations.configReady.fire()
#   except CatchableError as ex:
#     debug "Failed to receive workspace configuration", error = ex.msg

# proc maybeRequestConfigurationFromClient*(ls: LanguageServer) =
#   if supportsConfigurationRequest(ls):
#     debug "Requesting configuration from the client"
#     let configurationParams = %*{"items": [{"section": "nimTortoise"}, {"section": "nim"}]}
#     let configFuture = ls.call("workspace/configuration", configurationParams)
#     asyncSpawn ls.receiveConfiguration(configFuture)
#   else:
#     debug "Client does not support workspace/configuration"
#     ls.configurations.configReady.fire()


# proc getAndWaitForWorkspaceConfiguration*(
#   configurations: LanguageServerConfigurations
# ): Future[NlsConfig] {.async.} =
#   await configurations.configReady.wait()
#   return configurations.currentConfig
# # ls.getWorkspaceConfiguration()

# proc waitForWorkspaceConfiguration*(
#   configurations: LanguageServerConfigurations  
# ): Future[void] {.async.} =
#   ## Waits until workspace configuration is available, with a 30-second timeout.
#   ## configReady.wait() returns a fresh Future per caller, so cancelling this
#   ## future only removes it from the event's waiter list — it does not affect
#   ## other awaiters or the event itself. If the event has already fired,
#   ## wait() returns a completed Future immediately.
#   debug "Waiting for workspace configuration from client"
#   let completed = await configurations.configReady.wait().withTimeout(CONFIG_WAIT_TIMEOUT_MS.milliseconds)
#   if not completed:
#     warn "Workspace configuration not received within timeout; proceeding with defaults"
