import chronos

type
  NlsNimsuggestConfig* = ref object of RootObj
    projectFile*: string
    fileRegex*: string

  NlsWorkingDirectoryMaping* = ref object of RootObj
    projectFile*: string
    directory*: string

  NlsInlayTypeHintsConfig* = ref object of RootObj
    enable*: bool

  NlsInlayExceptionHintsConfig* = ref object of RootObj
    enable*: bool
    hintStringLeft*: string
    hintStringRight*: string

  NlsInlayParameterHintsConfig* = ref object of RootObj
    enable*: bool

  NlsInlayHintsConfig* = ref object of RootObj
    typeHints*:       NlsInlayTypeHintsConfig
    exceptionHints*:  NlsInlayExceptionHintsConfig
    parameterHints*:  NlsInlayParameterHintsConfig

  NlsNotificationVerbosity* = enum
    nvNone = "none"
    nvError = "error"
    nvWarning = "warning"
    nvInfo = "info"

type
  NlsConfig* = ref object of RootObj
    # --- Files/Folders ---
    projectMapping*: seq[NlsNimsuggestConfig]
    workingDirectoryMapping*: seq[NlsWorkingDirectoryMaping]
    # --- Save Settings ---
    checkOnSave*: bool
    formatOnSave*: bool
    # --- Langserver settings --- 
    langserverTimeout*: int
    fileCheckDelay*: int
    # -- Nimsuggest Settings ---
    maxNimsuggestProcesses*: int
    maxNimsuggestCrashRetries*: int
    nimsuggestPath*: string
    nimsuggestIdleTimeout*: int
    logNimsuggest*: bool
    inlayHints*: NlsInlayHintsConfig
    notificationVerbosity*: NlsNotificationVerbosity
    nimExpandArc*: bool
    nimExpandMacro*: bool
      
type
  LanguageServerConfigurations* = object
    currentConfig*: NlsConfig
      ## Parsed config. none until first workspace/configuration response arrives.
    configReady*: AsyncEvent
      ## Fired when currentConfig is first populated, and re-fired after each change.