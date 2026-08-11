import std/[os, sha1, tables, options]
import ./langserver_types
import ../utils/utils
import ../protocol/types

proc uriStorageLocation*(ls: LanguageServer, uri: FileUri): FilePath =
  # Use SHA-1 for a collision-resistant stash filename (40 hex chars).
  # std/hash is a 64-bit integer hash; two URIs could share it and silently
  # overwrite each other's edit buffer. SHA-1 collision probability is ~2^-80.
  return FilePath(ls.files.storageDir / ($secureHash(string(uri)) & ".nim"))

proc uriToStash*(ls: LanguageServer, uri: FileUri): FilePath =
  if ls.files.openFiles.hasKey(uri):
    return uriStorageLocation(ls, uri)
  else:
    return FilePath("")

proc toUtf16Pos*(
  ls: LanguageServer, uri: FileUri, line: int, utf8Pos: int
): Option[int] =
  if uri in ls.files.openFiles and line >= 0 and line < ls.files.openFiles[uri].fingerTable.len:
    let utf16Pos = ls.files.openFiles[uri].fingerTable[line].utf8to16(utf8Pos)
    return some(utf16Pos)
  else:
    return none(int)

proc getCharacter*(
  ls: LanguageServer, uri: FileUri, line: int, character: int
): Option[int] =
  if uri in ls.files.openFiles and line < ls.files.openFiles[uri].fingerTable.len:
    return some ls.files.openFiles[uri].fingerTable[line].utf16to8(character)
  else:
    return none(int)

proc getRootPath*(ip: LspInitializeParams): string =
  if ip.rootUri.isNone or ip.rootUri.get == FileUri(""):
    if ip.rootPath.isSome and ip.rootPath.get != "":
      return ip.rootPath.get
    else:
      return string(FilePath(getCurrentDir()).pathToUri.uriToPath)
  string(ip.rootUri.get.uriToPath)

proc getRootPath*(ip: McpInitializeParams): string =
  string(FilePath(getCurrentDir()).pathToUri.uriToPath)
