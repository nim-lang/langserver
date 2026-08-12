import std/[json, options, sequtils]
import chronos
import chronicles
import ./[configuration_types]

func inlayHintsEnabled*(cnf: NlsConfig): bool =
  return cnf.inlayHints.typeHints.enable or cnf.inlayHints.exceptionHints.enable or cnf.inlayHints.parameterHints.enable

proc initDefaultNlsConfig*(): NlsConfig = 
  return NlsConfig(
    # --- Files/Folders ---
    projectMapping: @[],
    workingDirectoryMapping: @[],
    # --- Save Settings ---
    checkOnSave: false,
    formatOnSave: false,
    # --- Langserver settings --- 
    langserverTimeout: 120_000, # in MS
    fileCheckDelay: 1000, # in MS
    # -- Nimsuggest Settings ---
    maxNimsuggestProcesses: 2, # max number of nimsuggest processes to keep alive. 0 means unlimited.
    maxNimsuggestCrashRetries: 3, # auto-restart attempts before giving up on a crashed slot
    nimsuggestPath: "nimsuggest",
    nimsuggestIdleTimeout: 60_000, #idle timeout in ms,
    logNimsuggest: true, # TODO - check createNimuggest function
    inlayHints: NlsInlayHintsConfig(
      typeHints: NlsInlayTypeHintsConfig(
        enable: true
      ),
      exceptionHints: NlsInlayExceptionHintsConfig(
        enable: true,
        hintStringLeft: "🔔",
        hintStringRight: ""
      ),
      parameterHints: NlsInlayParameterHintsConfig(
        enable: true
      ),
    ),
    notificationVerbosity: NlsNotificationVerbosity.nvInfo,
    nimExpandArc: false,
    nimExpandMacro: false,
    
    # delay in ms between file-change and per-file diagnostic check
  )

proc parseDidChangeConfiguration*(conf: JsonNode): NlsConfig =
  ## Parses a workspace/didChangeConfiguration push notification.
  ## Expected format: {"settings": {"nimTortoise": {...}}} or {"settings": {"nim": {...}}}
  try:
    if conf.kind == JObject and conf["settings"].kind == JObject:
      let settings = conf["settings"]
      if settings.hasKey("nimTortoise"):
        return settings["nimTortoise"].to(NlsConfig)
  except CatchableError:
    debug "Failed to parse didChangeConfiguration payload.", error = getCurrentExceptionMsg()
  return initDefaultNlsConfig()

proc parseWorkspaceConfigurationResponse*(conf: JsonNode): Option[NlsConfig] =
  ## Parses the response to a workspace/configuration request (pull model).
  ## Expected format: [<nimTortoise section>, <nim section>] — 1 or 2 elements.
  ## The nimTortoise section takes priority; the nim section fills in missing values.
  try:
    let items = if conf.kind == JArray: conf else: newJArray()
    if items.len == 0:
      return none(NlsConfig)
    else:
      if items[0].kind == JObject:
        return some(items[0].to(NlsConfig))
      else: 
        return none(NlsConfig)

  except CatchableError:
    debug "Failed to parse workspace/configuration response.", error = getCurrentExceptionMsg()
    return none(NlsConfig)
  
