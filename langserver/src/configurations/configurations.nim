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
