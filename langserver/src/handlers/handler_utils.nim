import std/[options, tables, sequtils, strutils, strformat, sugar]
import chronos
import regex
import with
import ../protocol/types
import ../langserver/[utils, langserver_types]
import ../nimsuggest/[suggestapi, suggestapi_types]
import ../utils/utils as globalUtils


proc toUtf8Col*(
  ls: LanguageServer, uri: FileUri, line: int, character: int
): Option[int] =
  if uri in ls.files.openFiles and line < ls.files.openFiles[uri].fingerTable.len:
    return some(ls.files.openFiles[uri].fingerTable[line].utf16to8(character))
  else:
    return none(int)

proc createRangeFromSuggest(suggest: Suggest): Range =
  result = range(suggest.line - 1, 0, suggest.endLine - 1, suggest.endCol)

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

proc toLocation*(suggest: Suggest): Location =
  return
    Location %* {"uri": pathToUri(suggest.filepath), "range": toLabelRange(suggest)}

proc toCompletionItem*(suggest: Suggest): CompletionItem =
  with suggest:
    return
      CompletionItem %* {
        "label": qualifiedPath[^1].strip(chars = {'`'}),
        "kind": nimSymToLSPKind(suggest).int,
        "documentation": doc,
        "detail": nimSymDetails(suggest),
      }

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

proc processLocationQuery*(
  ls: LanguageServer,
  nimsuggestResponse: seq[Suggest]
): seq[Location] =
  return nimsuggestResponse.map(x => x.toUtf16Pos(ls).toLocation)

