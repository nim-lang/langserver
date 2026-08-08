## Maps between vscode completion provider api and nimsuggest, auto-complete
## suggestions go brr.

import platform/vscodeApi
import platform/js/[jsString, jsre]
import std/[jsconsole, sequtils, tables]
import nimSuggestExec, nimImports
from nimProjects import getProjectFileInfo

proc vscodeKindFromNimSym(kind: cstring): VscodeCompletionKind =
  case $kind
  of "skConst": VscodeCompletionKind.value
  of "skEnumField": VscodeCompletionKind.`enum`
  of "skForVar": VscodeCompletionKind.variable
  of "skIterator": VscodeCompletionKind.keyword
  of "skLabel": VscodeCompletionKind.keyword
  of "skLet": VscodeCompletionKind.value
  of "skMacro": VscodeCompletionKind.snippet
  of "skMethod": VscodeCompletionKind.`method`
  of "skParam": VscodeCompletionKind.variable
  of "skProc": VscodeCompletionKind.function
  of "skResult": VscodeCompletionKind.value
  of "skTemplate": VscodeCompletionKind.snippet
  of "skType": VscodeCompletionKind.class
  of "skVar": VscodeCompletionKind.field
  of "skFunc": VscodeCompletionKind.function
  else: VscodeCompletionKind.property

proc nimSymDetails(suggest: NimSuggestResult): cstring =
  case $(suggest.suggest)
  of "skConst":
    "const " & suggest.fullName & ": " & suggest.`type`
  of "skEnumField":
    "enum " & suggest.`type`
  of "skForVar":
    "for var of " & suggest.`type`
  of "skIterator":
    suggest.`type`
  of "skLabel":
    "label"
  of "skLet":
    "let of " & suggest.`type`
  of "skMacro":
    "macro"
  of "skMethod":
    suggest.`type`
  of "skParam":
    "param"
  of "skProc":
    suggest.`type`
  of "skResult":
    "result"
  of "skTemplate":
    suggest.`type`
  of "skType":
    "type " & suggest.fullName
  of "skVar":
    "var of " & suggest.`type`
  else:
    suggest.`type`

proc provideCompletionItems*(
    doc: VscodeTextDocument,
    position: VscodePosition,
    newName: cstring,
    token: VscodeCancellationToken,
): Promise[seq[VscodeCompletionItem]] =
  return newPromise(
      proc(
          resolve: proc(val: seq[VscodeCompletionItem]), reject: proc(reason: JsObject)
      ) =
        let filename = doc.fileName
        let `range` = doc.getWordRangeAtPosition(position)
        var txt: cstring =
          if `range`.isNil():
            nil
          else:
            doc.getText(`range`).toLowerAscii()
        let line = doc.lineAt(position).text
        if line.startsWith("import "):
          var txtPart: cstring
          if txt.toJs().to(bool) and `range`.toJs().to(bool):
            txtPart = doc.getText(`range`.with(`end` = position)).toLowerAscii()
          else:
            txtPart = nil
          resolve(getImports(txtPart, getProjectFileInfo(filename).wsFolder.uri.fsPath))
        else:
          let startPos: cint = position.line + 1

          nimSuggestExec
          .execNimSuggest(
            NimSuggestType.sug,
            filename,
            startPos,
            position.character,
            true,
            doc.getText(),
          )
          .then(
            proc(items: seq[NimSuggestResult]) =
              var suggestions = initTable[string, VscodeCompletionItem]()
              if (not items.isNull() and not items.isUndefined()):
                for item in items:
                  if (
                    item.answerType == "sug" and
                    (txt.isNull() or item.symbolName.toLowerAscii().contains(txt)) and
                    newRegExp(r"[a-z]", r"i").test(item.symbolName)
                  ):
                    let suggestion: VscodeCompletionItem = vscode.newCompletionItem(
                      item.symbolName, vscodeKindFromNimSym(item.suggest)
                    )
                    suggestion.detail = nimSymDetails(item)
                    suggestion.sortText = (cstring("0000" & $suggestions.len))[^4 .. ^1]
                    # use predefined text to disable suggest sorting
                    suggestion.documentationMD =
                      vscode.newMarkdownString(item.documentation)
                    #deduplicate suggestions
                    let key = $item.symbolName
                    if key notin suggestions:
                      suggestions[key] = suggestion

              resolve(suggestions.values.toSeq())
          )
          .catch(
            proc(reason: JsObject) =
              reject(reason)
          )
    )
    .catch(
      proc(reason: JsObject): Promise[seq[VscodeCompletionItem]] =
        console.error("nimSuggest failed: ", reason)
        return promiseReject(reason).toJs().to(Promise[seq[VscodeCompletionItem]])
    )

var nimCompletionItemProvider* {.exportc.} = block:
  var o = newJsObject()
  o.provideCompletionItems = provideCompletionItems
  o.to(VscodeCompletionItemProvider)
