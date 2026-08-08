import std/[jsffi, jscore, asyncjs]
export jscore

type
  FsPromises* {.importc.} = ref object

  Fs* {.importc.} = ref object
    promises*: FsPromises

  FsStats* = ref FsStatsObj
  FsStatsObj {.importc.} = object of JsRoot
    mtime*: DateTime
    mtimeMs*: cint
    ctimeMs*: cint

  ErrnoException* = ref ErrnoExceptionObj
  ErrnoExceptionObj {.importc.} = object of JsRoot
    errno*: cint
    code*: cstring
    path*: cstring
    syscall*: cstring
    name*: cstring
    message*: cstring
    stack*: cstring

  ReaddirCallback* = proc(err: ErrnoException, files: seq[cstring]): void
  StatCallback* = proc(err: ErrnoException, stats: FsStats): void

  NodeFileHandle* {.importc.} = ref object of JsRoot

proc existsSync*(fs: Fs, file: cstring): bool {.importcpp.}
proc mkdirSync*(fs: Fs, file: cstring, recursive: bool = false): void {.importcpp.}
proc unlinkSync*(fs: Fs, file: cstring): void {.importcpp.}
proc stat*(fs: Fs, file: cstring, cb: StatCallback): void {.importcpp.}
proc statSync*(fs: Fs, file: cstring): FsStats {.importcpp.}
proc lstatSync*(fs: Fs, file: cstring): FsStats {.importcpp.}
proc readFileSync*(fs: Fs, file: cstring, encoding: cstring): cstring {.importcpp.}
proc writeFileSync*(fs: Fs, file: cstring, content: cstring): void {.importcpp.}
proc readdir*(fs: Fs, path: cstring, cb: ReaddirCallback): void {.importcpp.}
proc readdirSync*(fs: Fs, dir: cstring): seq[cstring] {.importcpp.}
proc rmdirSync*(fs: Fs, dir: cstring): void {.importcpp.}

# FsStats
proc isDirectory*(s: FsStats): bool {.importcpp.}

# Promises API
proc writeFile*(
  fp: FsPromises, path: cstring, data: cstring
): Future[void] {.importcpp: "#.writeFile(@)".}

proc open*(
  fp: FsPromises, path: cstring, options: cstring
): Future[NodeFileHandle] {.importcpp: "#.open(@)".}

proc unlink*(fp: FsPromises, path: cstring): Future[void] {.importcpp: "#.unlink(@)".}
proc copyFile*(
  fp: FsPromises, src: cstring, dest: cstring
): Future[void] {.discardable, importcpp: "#.copyFile(@)".}

proc readFileUtf8*(
  fp: FsPromises, path: cstring
): Future[cstring] {.importcpp: "#.readFile(#, {'encoding': 'utf8'})".}

proc close*(fh: NodeFileHandle): Future[void] {.discardable, importcpp.}
proc write*(
  fh: NodeFileHandle, data: cstring, position: cint
): Future[void] {.importcpp.}

proc writeFile*(fh: NodeFileHandle, data: cstring): Future[void] {.importcpp.}
proc sync*(fh: NodeFileHandle): Future[void] {.discardable, importcpp.}
proc truncate*(fh: NodeFileHandle): Future[void] {.discardable, importcpp.}
proc readFileUtf8*(
  fh: NodeFileHandle
): Future[cstring] {.importcpp: "#.readFile('utf8')".}

var fs*: Fs = require("fs").to(Fs)
var fsp*: FsPromises = fs.promises
