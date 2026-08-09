## Types for extension state, this should either get fleshed out or removed
import std/[options, times, strutils, jsconsole, tables]
import platform/vscodeApi

from platform/languageClientApi import VscodeLanguageClient
import ./[state_types]

proc getNimCmd*(state: ExtensionState): cstring =
  if state.nimDir == "":
    "nim ".cstring
  else:
    (state.nimDir & "/nim ").cstring

proc getTaskByName*(
    state: ExtensionState, name: cstring, projectDir: cstring = ""
): Option[NimbleTask] =
  for task in state.nimbleTasks:
    if task.name == name and (projectDir == "" or task.projectDir == projectDir):
      return some task
  none(NimbleTask)

proc markTaskAsRunning*(
    state: ExtensionState, name: cstring, projectDir: cstring, isRunning: bool
) =
  for task in state.nimbleTasks.mitems:
    if task.name == name and task.projectDir == projectDir:
      task.isRunning = isRunning
      break

proc addExtensionCapabilities*(state: ExtensionState, caps: seq[cstring]) =
  for cap in caps:
    try:
      let extCap = parseEnum[LspExtensionCapability]($cap)
      state.lspExtensionCapabilities.incl extCap
    except ValueError:
      console.error(("Error parsing server extension capability " & cap))
  # outputLine(fmt" Lsp Server Extension Capabilities: {state.lspExtensionCapabilities}".cstring)

proc onExtensionReady*(state: ExtensionState) =
  if state.extensionReady:
    return
  state.extensionReady = true
  for hook in state.onExtensionReadyHooks:
    hook()

proc fetchLsp*[T, U](
    state: ExtensionState, name: string, params: U
): Future[T] {.async.} =
  console.log("[FetchLsp] ", name, params.toJs())
  let response = await state.client.sendRequest(name, params.toJs())
  let res = jsonStringify(response).jsonParse(T)
  console.log(res)
  return res

proc fetchLsp*[T](state: ExtensionState, name: string): Future[T] =
  return fetchLsp[T, JsObject](state, name, ().toJs())

