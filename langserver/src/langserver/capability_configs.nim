import std/[json, options]
import chronos
import chronicles
import ../protocol/types
import ../configurations/[configurations, configuration_types]
import ../configurations/constants
import ./[langserver_types]

# proc getWorkspaceConfiguration*(ls: LanguageServer): NlsConfig =
#   ## Returns current config synchronously. Returns defaults if config not yet received.
#   ls.configurations.currentConfig.get(NlsConfig())

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
  return requiresDynamicRegistrationForDidChangeConfiguration(ls) and supportsConfigurationRequest(ls)
    
proc maybeRegisterCapabilityDidChangeConfiguration*(ls: LanguageServer) =
  if requiresDynamicRegistrationForDidChangeConfiguration(ls):
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
#   if ls.supportsConfigurationRequest():
#     debug "Requesting configuration from the client"
#     let configurationParams = %*{"items": [{"section": "nimTortoise"}, {"section": "nim"}]}
#     let configFuture = ls.call("workspace/configuration", configurationParams)
#     asyncSpawn ls.receiveConfiguration(configFuture)
#   else:
#     debug "Client does not support workspace/configuration"
#     ls.configurations.configReady.fire()
