import ./configuration_types

func `==`(a, b: NlsNimsuggestConfig): bool =
  if a.isNil and b.isNil: return true
  if a.isNil or b.isNil: return false
  a.projectFile == b.projectFile and a.fileRegex == b.fileRegex

func `==`(a, b: NlsWorkingDirectoryMaping): bool =
  if a.isNil and b.isNil: return true
  if a.isNil or b.isNil: return false
  a.projectFile == b.projectFile and a.directory == b.directory

func `==`(a, b: NlsInlayTypeHintsConfig): bool =
  if a.isNil and b.isNil: return true
  if a.isNil or b.isNil: return false
  a.enable == b.enable

func `==`(a, b: NlsInlayExceptionHintsConfig): bool =
  if a.isNil and b.isNil: return true
  if a.isNil or b.isNil: return false
  a.enable == b.enable and
  a.hintStringLeft == b.hintStringLeft and
  a.hintStringRight == b.hintStringRight

func `==`(a, b: NlsInlayParameterHintsConfig): bool =
  if a.isNil and b.isNil: return true
  if a.isNil or b.isNil: return false
  a.enable == b.enable

func `==`(a, b: NlsInlayHintsConfig): bool =
  if a.isNil and b.isNil: return true
  if a.isNil or b.isNil: return false
  a.typeHints == b.typeHints and
  a.exceptionHints == b.exceptionHints and
  a.parameterHints == b.parameterHints

proc isDifferentFrom*(newConfig: NlsConfig, currentConfig: NlsConfig): bool =
  ## Returns true if newConfig and currentConfig differ in any field value.
  let n = newConfig
  n.projectMapping != currentConfig.projectMapping or
  n.workingDirectoryMapping != currentConfig.workingDirectoryMapping or
  n.checkOnSave != currentConfig.checkOnSave or
  n.formatOnSave != currentConfig.formatOnSave or
  n.langserverTimeout != currentConfig.langserverTimeout or
  n.fileCheckDelay != currentConfig.fileCheckDelay or
  n.maxNimsuggestProcesses != currentConfig.maxNimsuggestProcesses or
  n.nimsuggestPath != currentConfig.nimsuggestPath or
  n.nimsuggestIdleTimeout != currentConfig.nimsuggestIdleTimeout or
  n.logNimsuggest != currentConfig.logNimsuggest or
  n.inlayHints != currentConfig.inlayHints or
  n.notificationVerbosity != currentConfig.notificationVerbosity or
  n.nimExpandArc != currentConfig.nimExpandArc or
  n.nimExpandMacro != currentConfig.nimExpandMacro


