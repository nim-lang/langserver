import std/[options, tables, sequtils, strutils, sugar]
import ../protocol/[enums, types]
import ../langserver/[utils, langserver_types]
import ../nim_tools/nimsuggest/suggestapi

proc toUtf8Col*(
  ls: LanguageServer, uri: string, line: int, character: int
): Option[int] =
  if uri in ls.files.openFiles and line < ls.files.openFiles[uri].fingerTable.len:
    return some ls.files.openFiles[uri].fingerTable[line].utf16to8(character)
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

proc toMarkupContent(suggest: Suggest): MarkupContent =
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
  nimsuggestResponse: seq[Suggest]
): seq[Location] = 
  return nimsuggestResponse.map(x => x.toUtf16Pos(ls).toLocation)

proc initNimsuggestPositionQuery*(
  ls: LanguageServer,
  id: int,
  uri: string,
  kind: NimsuggestQueryKind,
  line, character: int,
): Option[NimsuggestQuery] =
  ## Create a position-based query (hover, definition, completion, …).
  ## line is 0-based (LSP convention); converted to 1-based for nimsuggest internally."
  ## The dirtyFile is resolved automatically from the stash.
  let column = toUtf8Col(ls, line, character)
  if column.isNone:
    return none(NimsuggestQuery)
  else:
    ls.addProjectFileToPendingRequest(id.uint, uri)
    return some(NimsuggestQuery(
      id: id.uint,
      kind: kind,
      uri: uri,
      dirtyFile: ls.uriToStash(uri),
      responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
      position: FilePosition(line: line + 1, col: column.get),
    ))

proc initNimsuggestFileQuery*(
  ls: LanguageServer,
  id: int,
  uri: string,
  kind: NimsuggestQueryKind,
): Option[NimsuggestQuery] =
  ## Create a position-based query (hover, definition, completion, …).
  ## line is 0-based (LSP convention); converted to 1-based for nimsuggest internally."
  ## The dirtyFile is resolved automatically from the stash.
  let column = toUtf8Col(ls, line, character)
  if column.isNone:
    return none(NimsuggestQuery)
  else:
    ls.addProjectFileToPendingRequest(id.uint, uri)
    return some(NimsuggestQuery(
      id: id.uint,
      kind: kind,
      uri: uri,
      dirtyFile: ls.uriToStash(uri),
      responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
    ))


      let q = NimsuggestQuery(
    kind: kind,
    uri: uri,
    dirtyFile: ls.uriToStash(uri),
    responseFuture: newFuture[seq[Suggest]]("nimsuggestQuery"),
  )
  ls.routeQuery(uri, q)