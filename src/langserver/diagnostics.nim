import std/[sequtils, sugar, strutils, json, options, sets]
import with
import chronicles

import ../protocol/[types, enums]
import ../nim_tools/nimsuggest/nimsuggest_types
import ../nim_tools/nimcheck/nimcheck
import ./[langserver_types, utils]

proc toUtf16Pos*(checkResult: CheckResult, ls: LanguageServer): CheckResult =
  result = checkResult
  let uri = pathToUri(checkResult.file)
  let pos = toUtf16Pos(ls, uri, checkResult.line - 1, checkResult.column)
  if pos.isSome:
    result.column = pos.get()
  for i in 0 ..< result.stacktrace.len:
    let stPos =
      toUtf16Pos(ls, uri, result.stacktrace[i].line - 1, result.stacktrace[i].column)
    if stPos.isSome:
      result.stacktrace[i].column = stPos.get()

proc sendDiagnostics*(
    ls: LanguageServer, diagnostics: seq[Suggest] | seq[CheckResult], path: string
) =
  trace "Sending diagnostics", count = diagnostics.len, path = path
  let diagsJson = newJArray()
  for d in diagnostics.map(x => x.toUtf16Pos(ls).toDiagnosticJson):
    diagsJson.add(d)
  let params = %*{"uri": pathToUri(path), "diagnostics": diagsJson}
  ls.notify("textDocument/publishDiagnostics", params)
  if diagnostics.len != 0:
    ls.files.filesWithDiags.incl path
  else:
    ls.files.filesWithDiags.excl path
