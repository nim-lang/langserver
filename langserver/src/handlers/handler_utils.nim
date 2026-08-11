import std/[options, tables, sequtils, strutils, strformat]
import chronos
import regex
import ../protocol/types
import ../langserver/[langserver_types]
import ../nimsuggest/[suggestapi_types, diagnostics, nimsuggest_types]
import ../utils/utils as globalUtils

proc toUtf8Col*(
  ls: LanguageServer, uri: FileUri, line: int, character: int
): Option[int] =
  if uri in ls.files.openFiles and line < ls.files.openFiles[uri].fingerTable.len:
    return some(ls.files.openFiles[uri].fingerTable[line].utf16to8(character))
  else:
    return none(int)

proc fixIdentation(s: string, indent: int): string =
  result = s
    .split("\n")
    .mapIt(
      if (it != ""):
        repeat(" ", indent) & it
      else:
        it
    )
    .join("\n")

proc toMdLinks(s: string): string =
  result = s
  let matches = s.findAll(re2"`([^`<]*?)<([^`>]*?)>`_")
  for i in countDown(matches.high, matches.low):
    let match = matches[i]
    result[match.boundaries] = fmt"[{s[match.captures[0]]}]({s[match.captures[1]]})"

proc toMarkupContent*(suggest: Suggest): MarkupContent =
  result = MarkupContent(kind: "markdown", value: "```nim\n")
  result.value.add suggest.qualifiedPath.join(".")
  if suggest.forth.len != 0:
    result.value.add ": "
    result.value.add suggest.forth
  result.value.add "\n```"

  if suggest.doc.len != 0:
    result.value.add "\n\n---\n"
    result.value.add toMdLinks(suggest.doc)

proc initJsonRange*(startLine, startCharacter, endLine, endCharacter: int): Range =
  return
    Range %* {
      "start": {"line": startLine, "character": startCharacter},
      "end": {"line": endLine, "character": endCharacter},
    }

proc initLabelRange*(
  response: Suggest,
  ls: LanguageServer,
): Option[Range] = 
  let uri = pathToUri(response.filepath)
  let asLspFilePositionStart = toLspFilePosition(
    NimsuggestFilePosition(
      line: response.line,
      col: response.column
    ),
    uri,
    ls.files.openFiles
  )
  let textLength = utf16Len(response.qualifiedPath[^1])
  
  if asLspFilePositionStart.isSome:
    let startPos = asLspFilePositionStart.get()
    let rangeOutput = initJsonRange(
      int(startPos.line), int(startPos.character),
      int(startPos.line), int(startPos.character) + textLength,
    )
    return some(rangeOutput)
  else:
    return none(Range)

proc toLocationJson*(
  response: Suggest,
  ls: LanguageServer,
): Option[Location] = 
  let uri = pathToUri(response.filepath)
  let labelRange = initLabelRange(response, ls)
  if labelRange.isSome:
    let rangeJson = labelRange.get()
    let locationJson = Location %* {
      "uri": uri, 
      "range": rangeJson
    }
    return some(locationJson)
  else:
    return none(Location)

proc processLocationResponses*(
  nimsuggestResponses: seq[Suggest],
  ls: LanguageServer,
): seq[Location] =
  result = @[]
  for response in nimsuggestResponses:
    let locationJson = toLocationJson(response, ls)
    if locationJson.isSome:
      result.add(locationJson.get())
