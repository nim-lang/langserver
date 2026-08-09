import std/[options]
import ../protocol/types

type
  NlsNimsuggestConfig* = ref object of RootObj
    projectFile*: string
    fileRegex*: string

  NlsWorkingDirectoryMaping* = ref object of RootObj
    projectFile*: string
    directory*: string

  NlsInlayTypeHintsConfig* = ref object of RootObj
    enable*: Option[bool]

  NlsInlayExceptionHintsConfig* = ref object of RootObj
    enable*: Option[bool]
    hintStringLeft*: Option[string]
    hintStringRight*: Option[string]

  NlsInlayParameterHintsConfig* = ref object of RootObj
    enable*: Option[bool]

  NlsInlayHintsConfig* = ref object of RootObj
    typeHints*: Option[NlsInlayTypeHintsConfig]
    exceptionHints*: Option[NlsInlayExceptionHintsConfig]
    parameterHints*: Option[NlsInlayParameterHintsConfig]

  NlsNotificationVerbosity* = enum
    nvNone = "none"
    nvError = "error"
    nvWarning = "warning"
    nvInfo = "info"

  NlsConfig* = ref object of RootObj
    projectMapping*: OptionalSeq[NlsNimsuggestConfig]
    workingDirectoryMapping*: OptionalSeq[NlsWorkingDirectoryMaping]
    checkOnSave*: Option[bool]
    nimsuggestPath*: Option[string]
    timeout*: Option[int]
    autoRestart*: Option[bool]
    autoCheckFile*: Option[bool]
    autoCheckProject*: Option[bool]
    logNimsuggest*: Option[bool]
    inlayHints*: Option[NlsInlayHintsConfig]
    notificationVerbosity*: Option[NlsNotificationVerbosity]
    formatOnSave*: Option[bool]
    nimsuggestIdleTimeout*: Option[int] #idle timeout in ms
    useNimCheck*: Option[bool]
    nimExpandArc*: Option[bool]
    nimExpandMacro*: Option[bool]
    maxNimsuggestProcesses*: Option[int]
      #max number of nimsuggest processes to keep alive. zero means unlimited
