import std/[options, tables, sequtils, strutils, strformat, json]
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

func getTokenLength(rawName: string): int = 
  if rawName.startsWith(':'):    
    # compiler-internal, no source token
    # qualified path doesn't work for anonymous functions.
    return 1
  elif '`' in rawName:           
    # gensym: strip suffix
    return utf16Len(rawName[0 ..< rawName.find('`')])
  else:
    return utf16Len(rawName)

proc initLabelRangeForOpenFiles*(
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
  if asLspFilePositionStart.isSome:
    let startPos = asLspFilePositionStart.get()
    var textLength = getTokenLength(response.qualifiedPath[^1])

    let rangeOutput = initJsonRange(
      int(startPos.line), int(startPos.character),
      int(startPos.line), int(startPos.character) + textLength,
    )
    return some(rangeOutput)
  else:
    return none(Range)

proc toLocationJsonForOpenFiles*(
  response: Suggest,
  ls: LanguageServer,
): Option[Location] = 
  let uri = pathToUri(response.filepath)
  let labelRange = initLabelRangeForOpenFiles(response, ls)
  if labelRange.isSome:
    let rangeJson = labelRange.get()
    let locationJson = Location %* {
      "uri": uri, 
      "range": rangeJson
    }
    return some(locationJson)
  else:
    return none(Location)

proc getLspFilePositionByOpeningFile*(
  filepath: FilePath, 
  position: NimsuggestFilePosition
): LspFilePosition =
  ## Convert a nimsuggest UTF-8 column to a UTF-16 column by reading the file from disk.
  ## Falls back to utf8Col unchanged on any I/O error.
  try:
    let content = readFile(string(filepath))
    let lines = content.splitLines()
    let asLspLine = position.line - 1
    if asLspLine >= 0 and asLspLine < lines.len:
      let colValue = lines[asLspLine].createUTFMapping().utf8to16(position.col)
      return LspFilePosition(
        line: Line0Based(asLspLine),
        character: Utf16Int(colValue)
      )
  except IOError, OSError:
    discard

  return LspFilePosition(
    line: Line0Based(position.line - 1),
    character: Utf16Int(position.col)
  )

proc initLabelRangeForAnyFile*(
  response: Suggest, ls: LanguageServer,
): Range = 
  let filePos = NimsuggestFilePosition(
    line: response.line,
    col: response.column
  )
  let uri = pathToUri(response.filepath)
  if uri in ls.files.openFiles:
    let labelRange = initLabelRangeForOpenFiles(response, ls)
    if labelRange.isSome:
      let rangeJson = labelRange.get()
      return rangeJson

  let filePosition = getLspFilePositionByOpeningFile(
    response.filePath, filePos
  )
  let textLength = getTokenLength(response.qualifiedPath[^1])

  return initJsonRange(
    int(filePosition.line), 
    int(filePosition.character), 
    int(filePosition.line), 
    int(filePosition.character) + textLength
  )

proc toLocationJsonForAnyFile*(
  response: Suggest, ls: LanguageServer,
): Location = 
  let uri = pathToUri(response.filepath)
  let labelRange = initLabelRangeForAnyFile(response, ls)
  return Location %* {
    "uri": uri, 
    "range": labelRange
  }

proc processLocationResponsesForAnyFile*(
  nimsuggestResponses: seq[Suggest], 
  ls: LanguageServer,
): seq[Location] =
  ## Gets the range location for a file, either by querying the stored fingerTable, if it is an open file, or by reading the file directly from disk, if not
  result = @[]
  for response in nimsuggestResponses:
    result.add(toLocationJsonForAnyFile(response, ls))

