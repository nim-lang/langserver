## map between vscode and nimsuggest for providing parameter/signature completion

import platform/vscodeApi
import platform/js/[jsString, jsre]
import std/jsconsole
import nimSuggestExec

proc provideSignatureHelp(
    doc: VscodeTextDocument, position: VscodePosition, token: VscodeCancellationToken
): Promise[VscodeSignatureHelp] =
  return newPromise(
      proc(resolve: proc(val: VscodeSignatureHelp), reject: proc(reason: JsObject)) =
        let filename = doc.fileName

        var currentArgument: cint = 0
        var identBeforeDot: cstring = ""

        var lines = doc.getText().split("\n")
        var cursorX: cint = max(position.character - 1, 0)
        var cursorY = position.line
        var line = lines[cursorY]
        var bracketsWithin: cint = 0

        while (line[cursorX] != '(' or bracketsWithin != 0):
          if (line[cursorX] == ',' or line[cursorX] == ';') and bracketsWithin == 0:
            inc currentArgument
          elif line[cursorX] == ')':
            inc bracketsWithin
          elif line[cursorX] == '(':
            dec bracketsWithin
          else:
            discard

          dec cursorX

          if cursorX < 0:
            if cursorY <= 0:
              resolve(jsNull.to(VscodeSignatureHelp))
              return
            else:
              dec cursorY
              line = lines[cursorY]
              cursorX = max(cint(line.len - 1), 0)

        var dotPosition: cint = -1
        var start: cint = -1
        while cursorX >= 0:
          if line[cursorX] == '.':
            dotPosition = cursorX
            break
          dec cursorX

        while cursorX >= 0 and dotPosition != -1:
          case line[cursorX]
          of ' ', '\t', '(', '{', '=':
            start = cursorX + 1
            break
          else:
            dec cursorX

        if start == -1:
          start = 0

        if start != -1:
          let `end`: cint =
            if dotPosition == -1:
              0
            else:
              cint(dotPosition - 1)
          identBeforeDot = line[start .. `end`]

        var startPos: cint = position.line + 1

        execNimSuggest(
          NimSuggestType.con,
          filename,
          startPos,
          position.character,
          true,
          doc.getText(),
        )
        .then(
          proc(items: seq[NimSuggestResult]) =
            var signatures = vscode.newSignatureHelp()
            var isModule = 0
            if items.toJs().to(bool) and items.len > 0:
              signatures.activeSignature = 0

            if items.toJs().to(bool):
              for item in items:
                var signature =
                  vscode.newSignatureInformation(item.`type`, item.documentation)

                var genericsCleanType: cstring = ""
                var insideGeneric: cint = 0
                for i in [0 ..< (item.`type`.len)]:
                  if item.`type`[i] == "[":
                    inc insideGeneric
                  if insideGeneric <= 0:
                    genericsCleanType &= item.`type`[i]
                  if item.`type`[i] == "]":
                    dec insideGeneric

                var signatureCutDown = newRegExp(
                    r"(proc|macro|template|iterator|func) \((.+: .+)*\)", ""
                  )
                  .exec(genericsCleanType)
                if signatureCutDown.toJs().to(bool):
                  let parameters = signatureCutDown[2].split(", ")
                  for param in parameters:
                    signature.parameters.add(vscode.newParameterInformation(param))
                if item.names[0] == identBeforeDot or
                    item.path.find(newRegExp(identBeforeDot, "")) != -1 or
                    item.path.find(r"\\" & identBeforeDot & r"\\") != -1:
                  inc isModule
                signatures.signatures.add(signature)

            signatures.activeParameter =
              if isModule > 0 or identBeforeDot == "":
                currentArgument
              else:
                currentArgument + 1

            resolve(signatures)
        )
        .catch(
          proc(reason: JsObject) =
            # extra console.error can be removed once plugin is trustworthy
            console.error("nimSignature - execNimSuggest Failed", reason)
            reject(reason)
        )
    )
    .catch(
      proc(reason: JsObject): Promise[VscodeSignatureHelp] =
        console.error("nimSignature failure: ", reason)
        return promiseReject(reason).toJs().to(Promise[VscodeSignatureHelp])
    )

var nimSignatureProvider* {.exportc.} = block:
  var o = newJsObject()
  o.provideSignatureHelp = provideSignatureHelp
  o.to(VscodeSignatureHelpProvider)
