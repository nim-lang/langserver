import std/[sequtils, sugar, strutils, json, options, sets]
import with
import chronicles

import ../protocol/[types, enums]
import ../nimsuggest/nimsuggest_types
import ../nimcheck/nimcheck
import ./[langserver_types, utils]

proc toDiagnosticJson(suggest: Suggest): JsonNode =
  with suggest:
    let
      textStart = doc.find('\'')
      textEnd = doc.rfind('\'')
      endColumn =
        if textStart >= 0 and textEnd > textStart:
          column + utf16Len(doc[textStart + 1 ..< textEnd])
        else:
          column + 1

    let r = range(line - 1, column, line - 1, endColumn)
    result = %*{
      "uri": pathToUri(filePath),
      "range": %*{
        "start": %*{"line": r.start.line, "character": r.start.character},
        "end": %*{"line": r.`end`.line, "character": r.`end`.character},
      },
      "severity":
        case forth
        of "Error": DiagnosticSeverity.Error.int
        of "Hint": DiagnosticSeverity.Hint.int
        of "Warning": DiagnosticSeverity.Warning.int
        else: DiagnosticSeverity.Error.int
      ,
      "message": doc,
      "source": "nim",
      "code": "nimsuggest chk",
    }

proc toDiagnosticJson(checkResult: CheckResult): JsonNode =
  let
    textStart = checkResult.msg.find('\'')
    textEnd = checkResult.msg.rfind('\'')
    endColumn =
      if textStart >= 0 and textEnd >= 0 and textEnd > textStart:
        checkResult.column + utf16Len(checkResult.msg[textStart + 1 ..< textEnd])
      else:
        checkResult.column + 1

  let r = range(
    checkResult.line - 1,
    max(0, checkResult.column),
    checkResult.line - 1,
    max(0, endColumn),
  )
  result = %*{
    "uri": pathToUri(checkResult.file),
    "range": %*{
      "start": %*{"line": r.start.line, "character": r.start.character},
      "end": %*{"line": r.`end`.line, "character": r.`end`.character},
    },
    "severity":
      case checkResult.severity
      of "Error": DiagnosticSeverity.Error.int
      of "Hint": DiagnosticSeverity.Hint.int
      of "Warning": DiagnosticSeverity.Warning.int
      else: DiagnosticSeverity.Error.int
    ,
    "message": checkResult.msg,
    "source": "nim",
    "code": "nim check",
  }

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
