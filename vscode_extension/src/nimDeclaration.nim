## maps nimsuggest to vscode definition provider, this allows goto definition

import platform/vscodeApi
import nimSuggestExec

proc provideDefinition*(
    doc: VscodeTextDocument, position: VscodePosition, token: VscodeCancellationToken
): Promise[Array[VscodeLocation]] =
  ## TODO - the return type is a sub-set of what's in the TypeScript API
  ## Since we're providing the result this isn't a practical problem
  return newPromise(
    proc(resolve: proc(val: Array[VscodeLocation]), reject: proc(reason: JsObject)) =
      let pos: cint = position.line + 1

      execNimSuggest(
        NimSuggestType.def, doc.fileName, pos, position.character, true, doc.getText()
      )
      .then(
        proc(result: seq[NimSuggestResult]) =
          if (not result.isNull() and not result.isUndefined() and result.len > 0):
            let locations = newArray[VscodeLocation]()
            for def in result:
              if not (def.isUndefined() or def.isNull()):
                locations.push def.location

            if locations.len > 0:
              resolve(locations)

          resolve(jsNull.to(Array[VscodeLocation]))
      )
      .catch(
        proc(reason: JsObject) =
          reject(reason)
      )
  )

var nimDefinitionProvider* {.exportc.} = block:
  var o = newJsObject()
  o.provideDefinition = provideDefinition
  o.to(VscodeDefinitionProvider)
