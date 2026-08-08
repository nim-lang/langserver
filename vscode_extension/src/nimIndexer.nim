## this crawls the file system and indexes files and types so they're available
## for search providers (document, symbol, and outline). It caches this
## data inside our silly little flatfile database and reuses it between runs
## timestamps are used for invalidating the cache.

import platform/vscodeApi
import platform/js/[jsNodeFs, jsNodePath, jsString, jsre]
import store/flatdbnode

import std/[jsconsole, sequtils, asyncjs, os]
from std/jscore import Math, max

import nimStatus, nimSuggestExec

let dbVersion: cint = 5

var
  dbFiles: FlatDb
  dbTypes: FlatDb

type
  FileData = ref object of JsRoot
    file*: cstring
    timestamp*: cint

  SymbolData = ref object
    ws*: cstring ## TODO should be named more like workspace folder, not ws (workspace)
    file*: cstring
    range_start*: VscodePosition
    range_end*: VscodePosition
    `type`*: cstring
    container*: cstring
    kind*: VscodeSymbolKind

  IndexExcludeGlobs* = JsAssoc[cstring, bool]
    ## glob string -> bool mapping, comes from the files watcherExclude config
    ## we use this to avoid indexing things that we're not going to watch.

proc vscodeKindFromNimSym(kind: cstring): VscodeSymbolKind =
  case $kind
  of "skConst": VscodeSymbolKind.constant
  of "skEnumField": VscodeSymbolKind.`enum`
  of "skForVar", "skLet", "skParam", "skVar": VscodeSymbolKind.variable
  of "skIterator": VscodeSymbolKind.`array`
  of "skLabel": VscodeSymbolKind.`string`
  of "skMacro", "skProc", "skResult", "skFunc": VscodeSymbolKind.function
  of "skMethod": VscodeSymbolKind.`method`
  of "skTemplate": VscodeSymbolKind.`interface`
  of "skType": VscodeSymbolKind.class
  else: VscodeSymbolKind.property

proc getFileSymbols*(
    file: cstring, useDirtyFile: bool, dirtyFileContent: cstring = ""
): Future[seq[VscodeSymbolInformation]] {.async.} =
  console.log(
    "getFileSymbols - execnimsuggest - useDirtyFile",
    $(NimSuggestType.outline),
    file,
    useDirtyFile,
  )
  var items = await nimSuggestExec.execNimSuggest(
    NimSuggestType.outline, file, 0, 0, useDirtyFile, dirtyFileContent
  )

  var symbols: seq[VscodeSymbolInformation] = @[]
  var exists: seq[cstring] = @[]

  var res =
    if items.toJs().to(bool):
      items
    else:
      @[]
  try:
    for item in res:
      # skip let and var in proc and methods
      if item.suggest in ["skLet".cstring, "skVar"] and item.names.len >= 2:
        # module name + fn name
        continue

      var toAdd = $(item.column) & ":" & $(item.line)
      if not any(
        exists,
        proc(x: cstring): bool =
          x == toAdd.cstring,
      ):
        exists.add(toAdd.cstring)
        var symbolInfo = vscode.newSymbolInformation(
          item.symbolname,
          vscodeKindFromNimSym(item.suggest),
          item.containerName,
          item.location,
        )
        symbols.add(symbolInfo)
  except:
    var e = getCurrentException()
    console.error("getFileSymbols - failed", e)
    raise e
  return symbols

proc getDocumentSymbols*(
    file: cstring, useDirtyFile: bool, dirtyFileContent: cstring = ""
): Future[seq[VscodeDocumentSymbol]] {.async.} =
  console.log(
    "getDocumentSymbols - execnimsuggest - useDirtyFile",
    $(NimSuggestType.outline),
    file,
    useDirtyFile,
  )
  var items = await nimSuggestExec.execNimSuggest(
    NimSuggestType.outline, file, 0, 0, useDirtyFile, dirtyFileContent
  )

  var
    symbolMap = newMap[cstring, VscodeDocumentSymbol]()
    res =
      if items.toJs().to(bool):
        items
      else:
        @[]
  try:
    for item in res:
      if not symbolMap.has(item.fullName):
        symbolMap[item.fullName] = vscode.newDocumentSymbol(
          item.symbolname,
          cstring(""),
          vscodeKindFromNimSym(item.suggest),
          item.`range`, # we don't have the comment and other useful bits
          item.`range`,
        )
  except:
    var e = getCurrentException()
    console.error("getDocumentSymbols - failed", e)
    raise e

  let childrenToFilter = [cstring("skLet"), "skVar"]
  for item in res:
    if symbolMap.has(item.containerName):
      let
        parent = symbolMap[item.containerName]
        parentIsFuncLike = parent.kind == VscodeSymbolKind.function
        childIsLocalVarLike = item.suggest in childrenToFilter
        childName = item.fullName
      if not parentIsFuncLike and not childIsLocalVarLike:
        parent.children.add(symbolMap[childName])
      symbolMap.delete(childName)
    elif ":anonymous" in item.names:
      # filter out anonymous params we couldn't find a home for
      symbolMap.delete(item.fullName)

  return toSeq(symbolMap.values)

proc indexFile(file: cstring) {.async.} =
  let
    fsStat = fs.statSync(file)
    timestamp = Math.max(fsStat.mtimeMs, fsStat.ctimeMs)
    # doc query has a minor race condition for sub-second changes, but it's all
    #   transient data anyways
    doc = dbFiles
      .queryOne(equal("file", file) and higherEqual("timestamp", timestamp))
      .to(FileData)
    docNotFound = doc.isNil()

  if docNotFound:
    var infos = await getFileSymbols(file, false)

    if infos.isNull() or infos.len == 0:
      console.log("indexFile - nothing found")
      return

    var folder = vscode.workspace.getWorkspaceFolder(vscode.uriFile(file))
    try:
      discard await (dbFiles.delete equal("file", file))
      if not folder.isNil():
        dbFiles.insert(FileData{file: file, timestamp: timestamp})
    except:
      console.error(
        "indexFile - dbFiles", getCurrentExceptionMsg().cstring, getCurrentException()
      )

    try:
      discard await dbTypes.delete equal("file", file)

      if folder != nil:
        let moduleSymbol = SymbolData{
          ws: folder.uri.fsPath,
          file: vscode.uriFile(file).fsPath,
          range_start: vscode.newPosition(0, 0),
          range_end: vscode.newPosition(0, 0),
          `type`: path.basename(file, ".nim"),
          container: "",
          kind: VscodeSymbolKind.module,
        }

        console.log("indexFile - insertedModule", moduleSymbol)

        # add the module itself
        dbTypes.insert(moduleSymbol)

      for i in infos:
        var folder = vscode.workspace.getWorkspaceFolder(i.location.uri)
        if folder.isNil():
          console.log("indexFile - dbTypes - not in workspace", i.location.uri.fsPath)
          continue

        dbTypes.insert(
          SymbolData{
            ws: folder.uri.fsPath,
            file: i.location.uri.fsPath,
            range_start: i.location.`range`.start,
            range_end: i.location.`range`.`end`,
            `type`: i.name,
            container: i.containerName,
            kind: i.kind,
          }
        )
    except:
      console.error(
        "indexFile - dbTypes", getCurrentExceptionMsg().cstring, getCurrentException()
      )

proc removeFromIndex(file: cstring): void =
  dbFiles.delete equal("file", file)

proc addWorkspaceFile*(file: cstring): void =
  discard indexFile(file)

proc removeWorkspaceFile*(file: cstring): void =
  removeFromIndex(file)

proc changeWorkspaceFile*(file: cstring): void =
  discard indexFile(file)

proc getDbName(name: cstring, version: cint): cstring =
  return name & "_" & cstring($version) & ".db"

proc cleanOldDb(basePath: cstring, name: cstring): void =
  var dbPath: cstring = path.join(basePath, (name & ".db"))
  if fs.existsSync(dbPath):
    fs.unlinkSync(dbPath)

  for i in 0 ..< dbVersion:
    var dbPath = path.join(basepath, getDbName(name, cint(i)))
    if fs.existsSync(dbPath):
      fs.unlinkSync(dbPath)

proc indexWorkspaceFiles(filters: IndexExcludeGlobs) {.async.} =
  ## index the workspace files, exluding the ones in `filter`, this builds the
  ## list of types and files so various searching works
  let
    nimSuggestPath = nimSuggestExec.getNimSuggestPath()
    invalidNimSuggestPath = nimSuggestPath.isNil or nimSuggestPath == ""
    excludeGlob =
      cstring("{") & toSeq(filters.pairs).filterIt(it[1]).mapIt(it[0]).join(
        cstring(",")
      ) & cstring("}")
    hasExcludes = excludeGlob != "{}"
    urls =
      if invalidNimSuggestPath:
        await promiseResolve(newArray[VscodeUri]())
      elif hasExcludes:
        await vscode.workspace.findFiles(cstring("**" / "*.nim"), excludeGlob)
      else:
        await vscode.workspace.findFiles(cstring("**" / "*.nim"))

  console.log("exclude globs: ", excludeGlob)

  showNimProgress("Indexing, file count: " & cstring($urls.len))
  for i, url in urls:
    var cnt = urls.len - 1

    if cnt mod 20 == 0:
      updateNimProgress("Indexing: " & cstring($cnt) & " of " & cstring($urls.len))

    console.log("indexing: ", i, url)
    await indexFile(url.fsPath)

  hideNimProgress()

proc initWorkspace*(extPath: cstring, filters: IndexExcludeGlobs) {.async.} =
  ## clear the caches and index all the files

  # remove old version of indcies
  cleanOldDb(extPath, "files")
  cleanOldDb(extPath, "types")

  dbFiles = newFlatDb(path.join(extPath, getDbName("files", dbVersion)))
  dbTypes = newFlatDb(path.join(extPath, getDbName("types", dbVersion)))

  await indexWorkspaceFiles(filters)
  discard dbFiles.processCommands()
  discard dbTypes.processCommands()

proc findWorkspaceSymbols*(
    query: cstring
): Future[seq[VscodeSymbolInformation]] {.async.} =
  var
    symbols: seq[VscodeSymbolInformation] = @[]
    reg = newRegExp(query, r"i")
    folders = vscode.workspace.workspaceFolders
    folderPaths: seq[cstring] = @[]

  if not folders.toJs.to(bool):
    console.log("findWorkspaceSymbols - folder is empty:", folders)
    return symbols

  try:
    for f in folders:
      folderPaths.add(f.uri.fsPath)

    var docs = await dbTypes.query(
      qs().lim(100), oneOf("ws", folderPaths) and matches("type", reg)
    )

    for d in docs:
      var doc = d.to(SymbolData)
      symbols.add(
        vscode.newSymbolInformation(
          doc.`type`,
          doc.kind,
          doc.container,
          vscode.newLocation(
            vscode.uriFile(doc.file),
            vscode.newPosition(doc.range_start.line, doc.range_start.character),
          ),
        )
      )
  except:
    console.error("findWorkspaceSymbols - query exception", query, reg, folders)
    discard
  finally:
    return symbols

proc clearCaches*(filters: IndexExcludeGlobs) {.async.} =
  ## clear file and type caches, and reindex while excluding `filter`ed files
  if dbTypes != nil:
    await dbTypes.drop()
  if dbFiles != nil:
    await dbFiles.drop()
  await indexWorkspaceFiles(filters)

proc onClose*() {.async.} =
  allSettled(@[dbFiles.processCommands(), dbTypes.processCommands()])
