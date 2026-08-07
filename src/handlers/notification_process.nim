import std/[options, json, times]
import chronos
import chronicles
import ../protocol/types
import ../langserver/[langserver_types, configurations, utils, nimsuggest_processes]

# === initialized ===
proc initialized*(ls: LanguageServer, _: JsonNode): Future[void] {.async.} =
  debug "Client initialized."
  maybeRegisterCapabilityDidChangeConfiguration(ls)
  maybeRequestConfigurationFromClient(ls)
  await ls.waitForWorkspaceConfiguration()
  let rootPath = ls.capabilities.lspInitializeParams.getRootPath
  await ls.initNimsuggestInstances(rootPath)
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

