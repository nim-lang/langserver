import std/[json, options]
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

proc nlsConfigFromJson*(json: JsonNode): NlsConfig =
  ## Build an NlsConfig by overlaying `json` onto defaults.
  ## Missing keys keep their default values; extra keys are ignored.
  result = initDefaultNlsConfig()
  if json.kind != JObject:
    return

  if json.hasKey("projectMapping"):
    result.projectMapping = json["projectMapping"].to(seq[NlsNimsuggestConfig])
  if json.hasKey("workingDirectoryMapping"):
    result.workingDirectoryMapping = json["workingDirectoryMapping"].to(seq[NlsWorkingDirectoryMaping])
  if json.hasKey("checkOnSave"):
    result.checkOnSave = json["checkOnSave"].getBool()
  if json.hasKey("formatOnSave"):
    result.formatOnSave = json["formatOnSave"].getBool()
  if json.hasKey("langserverTimeout"):
    result.langserverTimeout = json["langserverTimeout"].getInt()
  if json.hasKey("fileCheckDelay"):
    result.fileCheckDelay = json["fileCheckDelay"].getInt()
  if json.hasKey("maxNimsuggestProcesses"):
    result.maxNimsuggestProcesses = json["maxNimsuggestProcesses"].getInt()
  if json.hasKey("maxNimsuggestCrashRetries"):
    result.maxNimsuggestCrashRetries = json["maxNimsuggestCrashRetries"].getInt()
  if json.hasKey("nimsuggestPath"):
    result.nimsuggestPath = json["nimsuggestPath"].getStr()
  if json.hasKey("nimsuggestIdleTimeout"):
    result.nimsuggestIdleTimeout = json["nimsuggestIdleTimeout"].getInt()
  if json.hasKey("logNimsuggest"):
    result.logNimsuggest = json["logNimsuggest"].getBool()
  if json.hasKey("nimExpandArc"):
    result.nimExpandArc = json["nimExpandArc"].getBool()
  if json.hasKey("nimExpandMacro"):
    result.nimExpandMacro = json["nimExpandMacro"].getBool()
  if json.hasKey("notificationVerbosity"):
    try:
      result.notificationVerbosity = json["notificationVerbosity"].to(NlsNotificationVerbosity)
    except CatchableError:
      discard  # keep default if value is unrecognised
  if json.hasKey("inlayHints") and json["inlayHints"].kind == JObject:
    let ih = json["inlayHints"]
    let hints = result.inlayHints   # ref — mutate in place
    if ih.hasKey("typeHints") and ih["typeHints"].kind == JObject:
      if ih["typeHints"].hasKey("enable"):
        hints.typeHints.enable = ih["typeHints"]["enable"].getBool()
    if ih.hasKey("parameterHints") and ih["parameterHints"].kind == JObject:
      if ih["parameterHints"].hasKey("enable"):
        hints.parameterHints.enable = ih["parameterHints"]["enable"].getBool()
    if ih.hasKey("exceptionHints") and ih["exceptionHints"].kind == JObject:
      let eh = ih["exceptionHints"]
      if eh.hasKey("enable"):
        hints.exceptionHints.enable = eh["enable"].getBool()
      if eh.hasKey("hintStringLeft"):
        hints.exceptionHints.hintStringLeft = eh["hintStringLeft"].getStr()
      if eh.hasKey("hintStringRight"):
        hints.exceptionHints.hintStringRight = eh["hintStringRight"].getStr()

proc parseDidChangeConfiguration*(conf: JsonNode): NlsConfig =
  ## Parses a workspace/didChangeConfiguration push notification.
  ## Expected format: {"settings": {"nimTortoise": {...}}} or {"settings": {"nim": {...}}}
  try:
    if conf.kind == JObject and conf["settings"].kind == JObject:
      let settings = conf["settings"]
      if settings.hasKey("nimTortoise"):
        return nlsConfigFromJson(settings["nimTortoise"])
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
    if items[0].kind == JObject:
      return some(nlsConfigFromJson(items[0]))
    return none(NlsConfig)
  except CatchableError:
    debug "Failed to parse workspace/configuration response.", error = getCurrentExceptionMsg()
    return none(NlsConfig)
  
