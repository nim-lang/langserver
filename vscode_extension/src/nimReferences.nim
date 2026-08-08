## map between vscode and nimsuggest for providing a list of places a symbol
## is referenced.

import platform/vscodeApi
import nimSuggestExec

proc provideReferences*(
    doc: VscodeTextDocument,
    position: VscodePosition,
    options: VscodeReferenceContext,
    token: VscodeCancellationToken,
): Promise[seq[VscodeLocation]] =
  return newPromise(
    proc(resolve: proc(val: seq[VscodeLocation]), reject: proc(reason: JsObject)) =
      vscode.workspace
      .saveAll(false)
      .then(
        proc() =
          let pos: cint = position.line + 1

          execNimSuggest(
            NimSuggestType.use,
            doc.fileName,
            pos,
            position.character,
            true,
            doc.getText(),
          )
          .then(
            proc(results: seq[NimSuggestResult]) =
              var references: seq[VscodeLocation] = @[]
              if (not result.isNull() and not result.isUndefined()):
                for item in results:
                  references.add(item.location)
                resolve(references)
              else:
                resolve(jsNull.to(seq[VscodeLocation]))
          )
          .catch(
            proc(reason: JsObject) =
              reject(reason)
          )
      )
      .catch(
        proc(reason: JsObject) =
          reject(reason)
      )
  )

var nimReferenceProvider* {.exportc.} = block:
  var o = newJsObject()
  o.provideReferences = provideReferences
  o.to(VscodeReferenceProvider)
