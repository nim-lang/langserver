import std/[options, json, times]
import chronos
import chronicles
import ../protocol/types
import ../langserver/langserver
import ../configurations/configurations

# === initialized ===
proc initialized*(ls: LanguageServer, _: JsonNode): Future[void] {.async.} =
  debug "Client initialized."
  ls.maybeRegisterCapabilityDidChangeConfiguration()

  # ls.maybeRequestConfigurationFromClient()
  # proc maybeRequestConfigurationFromClient*(ls: LanguageServer) =

  if ls.supportsConfigurationRequest:
    debug "Requesting configuration from the client"
    
    let configurationParams = %*{"items": [{"section": "nimTortoise"}, {"section": "nim"}]}
    
    let configFuture = ls.call("workspace/configuration", configurationParams)

    try:
      let conf = await configFuture
      debug "Received the following configuration", configuration = conf
      let newConfiguration: Option[NlsConfig] = parseWorkspaceConfigurationResponse(conf)
      if newConfiguration.isSome: 
        let newConfigValue = newConfiguration.get()
        let newConfigurationIsDifferent = isDifferentFrom(newConfigValue, ls.configurations.currentConfig)

        if newConfigurationIsDifferent:
          ls.configurations.currentConfig = newConfigValue

      ls.configurations.configReady.fire()
    except CatchableError as ex:
      debug "Failed to receive workspace configuration", error = ex.msg

    # asyncSpawn ls.receiveConfiguration(configFuture)
  else:
    debug "Client does not support workspace/configuration"
    ls.configurations.configReady.fire()
  
  # debug "Waiting for workspace configuration from client"
  # let completed = await withTimeout(ls.configurations.configReady.wait(), milliseconds(CONFIG_WAIT_TIMEOUT_MS))

  # if not completed:
  #   warn "Workspace configuration not received within timeout; proceeding with defaults"

  # await ls.waitForWorkspaceConfiguration()
  await ls.initNimsuggestInstances(
    ls.capabilities.lspInitializeParams.getRootPath
  )

  if not ls.lsInitialized.finished:
    ls.lsInitialized.complete()
  
# === $/cancelRequest ===
proc cancelRequest*(ls: LanguageServer, params: CancelParams): Future[void] {.async.} =
  if params.id.isSome:
    let id = params.id.get.getInt.uint
    if id notin ls.messaging.pendingRequests:
      return
    debug "Cancelling: ", id = id
    ls.messaging.pendingRequests[id].state = prsCancelled
    ls.messaging.pendingRequests[id].endTime = now()
    let query = ls.messaging.pendingRequests[id].query
    if query.isSome:
      query.get.cancelled = true
      ## processQueries checks this flag before dispatching the TCP call.
      ## If already dispatched, the in-flight call completes normally with @[].
      ## No future cancellation exception is thrown — handlers get empty results.

# === $/setTrace ===
proc setTrace*(ls: LanguageServer, params: SetTraceParams) {.async.} =
  debug "setTrace", value = params.value

