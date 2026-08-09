import std/[json, options]
import chronos
import chronicles
import ./[configuration_types]

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

proc mergeConfigs*(primary, fallback: NlsConfig): NlsConfig =
  ## Returns primary config with any none fields filled from fallback.
  result = primary
  if result.projectMapping.isNone or result.projectMapping.get(@[]).len == 0:
    result.projectMapping = fallback.projectMapping
  if result.workingDirectoryMapping.isNone or result.workingDirectoryMapping.get(@[]).len == 0:
    result.workingDirectoryMapping = fallback.workingDirectoryMapping
  if result.checkOnSave.isNone:             result.checkOnSave             = fallback.checkOnSave
  if result.nimsuggestPath.isNone:          result.nimsuggestPath          = fallback.nimsuggestPath
  if result.timeout.isNone:                 result.timeout                 = fallback.timeout
  if result.autoRestart.isNone:             result.autoRestart             = fallback.autoRestart
  if result.autoCheckFile.isNone:           result.autoCheckFile           = fallback.autoCheckFile
  if result.autoCheckProject.isNone:        result.autoCheckProject        = fallback.autoCheckProject
  if result.logNimsuggest.isNone:           result.logNimsuggest           = fallback.logNimsuggest
  if result.inlayHints.isNone:              result.inlayHints              = fallback.inlayHints
  if result.notificationVerbosity.isNone:   result.notificationVerbosity   = fallback.notificationVerbosity
  if result.formatOnSave.isNone:            result.formatOnSave            = fallback.formatOnSave
  if result.nimsuggestIdleTimeout.isNone:   result.nimsuggestIdleTimeout   = fallback.nimsuggestIdleTimeout
  if result.useNimCheck.isNone:             result.useNimCheck             = fallback.useNimCheck
  if result.nimExpandArc.isNone:            result.nimExpandArc            = fallback.nimExpandArc
  if result.nimExpandMacro.isNone:          result.nimExpandMacro          = fallback.nimExpandMacro
  if result.maxNimsuggestProcesses.isNone:  result.maxNimsuggestProcesses  = fallback.maxNimsuggestProcesses
  if result.fileCheckDelay.isNone:          result.fileCheckDelay          = fallback.fileCheckDelay

proc parseWorkspaceConfiguration*(conf: JsonNode): NlsConfig =
  # Format A: {"settings": {"nimTortoise": {...}}} or {"settings": {"nim": {...}}}
  try:
    if conf.kind == JObject and conf["settings"].kind == JObject:
      let settings = conf["settings"]
      if settings.hasKey("nimTortoise"):
        return settings["nimTortoise"].to(NlsConfig)
      return settings["nim"].to(NlsConfig)
  except CatchableError:
    discard
  # Format B: array from workspace/configuration response — may have 1 or 2 elements
  try:
    let nlsConfigs: seq[NlsConfig] = (%conf).to(seq[NlsConfig])
    let primary  = if nlsConfigs.len > 0 and nlsConfigs[0] != nil: nlsConfigs[0] else: NlsConfig()
    let fallback = if nlsConfigs.len > 1 and nlsConfigs[1] != nil: nlsConfigs[1] else: NlsConfig()
    return mergeConfigs(primary, fallback)
  except CatchableError:
    debug "Failed to parse the configuration.", error = getCurrentExceptionMsg()
    result = NlsConfig()

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
