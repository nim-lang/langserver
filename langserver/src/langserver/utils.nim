import std/[os, sha1, tables, options]
import ./langserver_types
import ../nimsuggest/suggestapi_types
import ../utils/utils
import ../protocol/types

proc uriStorageLocation*(ls: LanguageServer, uri: string): string =
  # Use SHA-1 for a collision-resistant stash filename (40 hex chars).
  # std/hash is a 64-bit integer hash; two URIs could share it and silently
  # overwrite each other's edit buffer. SHA-1 collision probability is ~2^-80.
  ls.files.storageDir / ($secureHash(uri) & ".nim")

proc uriToStash*(ls: LanguageServer, uri: string): string =
  if ls.files.openFiles.hasKey(uri) and ls.files.openFiles[uri].changed:
    uriStorageLocation(ls, uri)
  else:
    ""

proc toUtf16Pos*(
    ls: LanguageServer, uri: string, line: int, utf8Pos: int
): Option[int] =
  if uri in ls.files.openFiles and line >= 0 and line < ls.files.openFiles[uri].fingerTable.len:
    let utf16Pos = ls.files.openFiles[uri].fingerTable[line].utf8to16(utf8Pos)
    return some(utf16Pos)
  else:
    return none(int)

proc toUtf16Pos*(suggest: Suggest, ls: LanguageServer): Suggest =
  result = suggest
  let uri = pathToUri(suggest.filePath)
  let pos = toUtf16Pos(ls, uri, suggest.line - 1, suggest.column)
  if pos.isSome:
    result.column = pos.get()

proc toUtf16Pos*(
    suggest: SuggestInlayHint, ls: LanguageServer, uri: string
): SuggestInlayHint =
  result = suggest
  let pos = toUtf16Pos(ls, uri, suggest.line - 1, suggest.column)
  if pos.isSome:
    result.column = pos.get()

proc getCharacter*(
    ls: LanguageServer, uri: string, line: int, character: int
): Option[int] =
  if uri in ls.files.openFiles and line < ls.files.openFiles[uri].fingerTable.len:
    return some ls.files.openFiles[uri].fingerTable[line].utf16to8(character)
  else:
    return none(int)

proc getRootPath*(ip: LspInitializeParams): string =
  if ip.rootUri.isNone or ip.rootUri.get == "":
    if ip.rootPath.isSome and ip.rootPath.get != "":
      return ip.rootPath.get
    else:
      return getCurrentDir().pathToUri.uriToPath
  ip.rootUri.get.uriToPath

proc getRootPath*(ip: McpInitializeParams): string =
  getCurrentDir().pathToUri.uriToPath
