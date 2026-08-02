import std/[sequtils, sugar]
import with

import ../protocol/[types, enums]
import ../nimsuggest/nimsuggest_types
import ../nimcheck/nimcheck
import ./[langserver_types, utils]

proc toDiagnostic(suggest: Suggest): Diagnostic =
  with suggest:
    let
      textStart = doc.find('\'')
      textEnd = doc.rfind('\'')
      endColumn =
        if textStart >= 0 and textEnd > textStart:
          column + utf16Len(doc[textStart + 1 ..< textEnd])
        else:
          column + 1

    let node =
      %*{
        "uri": pathToUri(filepath),
        "range": range(line - 1, column, line - 1, endColumn),
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
    return node.to(Diagnostic)

proc toDiagnostic(checkResult: CheckResult): Diagnostic =
  let
    textStart = checkResult.msg.find('\'')
    textEnd = checkResult.msg.rfind('\'')
    endColumn =
      if textStart >= 0 and textEnd >= 0 and textEnd > textStart:
        checkResult.column + utf16Len(checkResult.msg[textStart + 1 ..< textEnd])
      else:
        checkResult.column + 1

  let node =
    %*{
      "uri": pathToUri(checkResult.file),
      "range": range(
        checkResult.line - 1,
        max(0, checkResult.column),
        checkResult.line - 1,
        max(0, endColumn),
      ),
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
  return node.to(Diagnostic)

proc sendDiagnostics*(
    ls: LanguageServer, diagnostics: seq[Suggest] | seq[CheckResult], path: string
) =
  trace "Sending diagnostics", count = diagnostics.len, path = path
  let params =
    PublishDiagnosticsParams %* {
      "uri": pathToUri(path),
      "diagnostics": diagnostics.map(x => x.toUtf16Pos(ls).toDiagnostic),
    }
  ls.notify("textDocument/publishDiagnostics", %params)
  if diagnostics.len != 0:
    ls.filesWithDiags.incl path
  else:
    ls.filesWithDiags.excl path
