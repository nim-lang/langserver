import std/[sequtils, sugar, json, options, strutils]
import chronicles

import ../utils/utils as globalUtils
import ./[suggestapi_types, nimsuggest_types]
import ../protocol/[types, enums]

proc toLspFilePosition*(
  position: NimsuggestFilePosition,
  uri: FileUri,
  openFiles: TableRef[FileUri, NlsFileInfo], 
): Option[LspFilePosition] =
  if uri in openFiles:
    let lspLine = position.line - 1 # Convert to 0-based from 1-based
    if position.line >= 0 and position.line < openFiles[uri].fingerTable.len:
      let utf8Col = position.col
      let lspChar = openFiles[uri].fingerTable[lspLine].utf8to16(utf8Col)
      return some(LspFilePosition(
        line: Line0Based(lspLine),
        character: Utf16Int(lspChar)
      ))

  return none(LspFilePosition)

func toLspFilePosition(
  suggest: Suggest, uri: FileUri, openFiles: TableRef[FileUri, NlsFileInfo], 
): Option[tuple[start, finish: LspFilePosition]] =
  let textStart = suggest.doc.find('\'')
  let textEnd = suggest.doc.rfind('\'')
  var startCharacter = 0
  var endCharacter = 1

  let startingNimsuggestFilePosition = NimsuggestFilePosition(
    line: suggest.line,
    col: suggest.column
  )

  let asLspFilePosition = toLspFilePosition(
    startingNimsuggestFilePosition, uri, openFiles
  )

  if asLspFilePosition.isSome:
    var textLength = 1
    if textStart >= 0 and textEnd > textStart:
      textLength = utf16Len(suggest.doc[textStart + 1 ..< textEnd])
    
    let startPos = asLspFilePosition.get()
    return some((
      start: startPos,
      finish: LspFilePosition(
        line: Line0Based(startPos.line),
        character: Utf16Int(int(startPos.character) + textLength)
      )
    ))

  else:
    return none(tuple[start, finish: LspFilePosition]) 

proc toDiagnosticJson*(
  suggest: Suggest, 
  uri: FileUri, 
  openFiles: TableRef[FileUri, NlsFileInfo]
): Option[JsonNode] =
  let asLspFilePosition = toLspFilePosition(suggest, uri, openFiles)
  if asLspFilePosition.isSome:
    let positions = asLspFilePosition.get()

    let jsonToSend = %*{
      "uri": pathToUri(suggest.filePath),
      "range": %*{
        "start": %*{
          "line": int(positions.start.line), 
          "character": int(positions.start.character)
        },
        "end": %*{
          "line": int(positions.finish.line), 
          "character": int(positions.finish.character)
        },
      },
      "severity":
        case suggest.forth
        of "Error": DiagnosticSeverity.Error.int
        of "Hint": DiagnosticSeverity.Hint.int
        of "Warning": DiagnosticSeverity.Warning.int
        else: DiagnosticSeverity.Error.int
      ,
      "message": suggest.doc,
      "source": "nim",
      "code": "nimsuggest chk",
    }
    return some(jsonToSend)
  else:
    return none(JsonNode)

proc convertNimSuggestResponseToDiagnostics*(
  suggestResponses: seq[Suggest], 
  uri: FileUri, 
  openFiles: TableRef[FileUri, NlsFileInfo]
): JsonNode =
  let filteredResponses = suggestResponses.filter(s => string(s.filePath) != "???")
  var diagnosticJson = newJArray()
  for d in filteredResponses:
    let converted = toDiagnosticJson(d, uri, openFiles)
    if converted.isSome:
      diagnosticJson.add(converted.get())

  let jsonToSend = %*{"uri": uri, "diagnostics": diagnosticJson }
  return jsonToSend

# Language Server Protocol: Diagnostics

## What part of LSP creates red squiggly lines?

# In the **Language Server Protocol (LSP)**, red squiggly lines for things that are wrong are handled by **Diagnostics**.

# The key mechanism is:

# - **`textDocument/publishDiagnostics`** — the language server sends diagnostics to the editor.
# - Each **`Diagnostic`** can contain:
#   - `range` — the text location to underline
#   - `message` — what’s wrong
#   - `severity` — `Error`, `Warning`, `Information`, or `Hint`
#   - optionally `code`, `source`, related information, etc.

# For example:

# ```json
# {
#   "method": "textDocument/publishDiagnostics",
#   "params": {
#     "uri": "file:///example.ts",
#     "diagnostics": [
#       {
#         "range": {
#           "start": { "line": 4, "character": 10 },
#           "end": { "line": 4, "character": 15 }
#         },
#         "severity": 1,
#         "message": "Cannot find name 'foobar'."
#       }
#     ]
#   }
# }
# ```

# The editor receives the diagnostic and renders it as the familiar **red squiggly underline**.

# ---

## Are diagnostics a response to a request?

# No. Diagnostics are **not the response to a request**.

# `textDocument/publishDiagnostics` is a **server → client notification**. It has no request ID and the client does not send a response.

# A typical interaction looks like:

# ```text
# IDE → language server
#      textDocument/didOpen
#      textDocument/didChange
#      ...

# IDE ← language server
#      textDocument/publishDiagnostics   ← notification
# ```

# The common sequence is:

# 1. The user edits a file.
# 2. The IDE sends `textDocument/didChange`.
# 3. The language server analyzes the file.
# 4. The language server sends `textDocument/publishDiagnostics`.
# 5. The IDE updates the squiggly underlines.

# The protocol does not require a diagnostic publication to be directly tied to a particular `didChange` request, however. The server can publish diagnostics whenever appropriate.

# ---

# ## What does an empty diagnostics array mean?

# For example:

# ```json
# {
#   "uri": "file:///example.ts",
#   "diagnostics": []
# }
# ```

# This means:

# > There are currently no diagnostics for this document.

# The client should therefore **clear the previously published diagnostics for that URI**.

# For example, the server might first send:

# ```json
# {
#   "uri": "file:///example.ts",
#   "diagnostics": [
#     {
#       "range": {
#         "start": { "line": 4, "character": 10 },
#         "end": { "line": 4, "character": 15 }
#       },
#       "severity": 1,
#       "message": "Cannot find name 'foo'."
#     }
#   ]
# }
# ```

# The IDE displays the red squiggly.

# After the user fixes the problem, the server can send:

# ```json
# {
#   "uri": "file:///example.ts",
#   "diagnostics": []
# }
# ```

# The IDE then removes the squiggly.

# So an empty diagnostics array is **not** "nothing happened." It means:

# > **Replace the diagnostics for this document with an empty set.**

# ---

# ## Key takeaway

# Diagnostics are best thought of as **state published by the language server**, rather than as the result of a request.

# Each `textDocument/publishDiagnostics` notification communicates the current set of diagnostics for a particular document URI. An empty array tells the client that the document currently has **no diagnostics**, causing previously displayed diagnostics for that document to be cleared.
