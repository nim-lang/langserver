import std/jsffi
import jsNode
export jsNode.Buffer, jsNode.toString

type
  StreamWriteable* = ref StreamWriteableObj
  StreamWriteableObj {.importc.} = object of JsRoot

  StreamReadable* = ref StreamReadableObj
  StreamReadableObj {.importc.} = object of JsRoot

  ChildProcess* = ref ChildProcessObj
  ChildProcessObj {.importc.} = object of JsRoot
    pid*: cint
    stdin*: StreamWriteable
    stdout*: StreamReadable
    stderr*: StreamReadable

  BaseError* = ref BaseErrorObj
  BaseErrorObj {.importc.} = object of JsError
    name*: cstring
    stack*: cstring

  ChildError* = ref ChildErrorObj
  ChildErrorObj {.importc.} = object of BaseError
    code*: cstring

  ExecError* = ref ExecErrorObj
  ExecErrorObj {.importc.} = object of BaseError
    cmd*: cstring
    killed*: bool
    code*: cint
    signal*: cstring

  SpawnSyncReturn* = ref SpawnSyncReturnObj
  SpawnSyncReturnObj {.importc.} = object of JsObject
    status*: cint
    error*: ChildError
    output*: seq[cstring]

  ExecOptions* = ref object
    cwd*: cstring

  SpawnOptions* = ref object
    cwd*: cstring
    shell*: bool

  SpawnSyncOptions* = ref object
    cwd*: cstring

  ChildProcessModule* = ref ChildProcessModuleObj
  ChildProcessModuleObj {.importc.} = object of JsRoot

  ExecCallback* = proc(error: ExecError, stdout: cstring, stderr: cstring): void

# node module interface
proc spawn*(
  cpm: ChildProcessModule, cmd: cstring, args: seq[cstring], opt: SpawnOptions
): ChildProcess {.importcpp.}

proc spawnSync*(
  cpm: ChildProcessModule, cmd: cstring, args: seq[cstring], opt: SpawnSyncOptions
): SpawnSyncReturn {.importcpp.}

proc exec*(
  cpm: ChildProcessModule, cmd: cstring, options: ExecOptions, cb: ExecCallback
): ChildProcess {.importcpp.}

proc execSync*(
  cpm: ChildProcessModule, cmd: cstring, options: ExecOptions, cb: ExecCallback
): Buffer {.importcpp.}

proc execSync*(
  cpm: ChildProcessModule, cmd: cstring, options: ExecOptions
): Buffer {.importcpp.}

proc execFileSync*(
  cpm: ChildProcessModule, cmd: cstring, args: seq[cstring]
): Buffer {.importcpp.}

# ChildProcess
proc kill*(cp: ChildProcess): void {.importcpp.}
proc kill*(cp: ChildProcess, signal: cstring): void {.importcpp.}
proc onError*(
  cp: ChildProcess, listener: proc(err: ChildError): void
): ChildProcess {.importcpp: "#.on(\"error\",@)", discardable.}

proc onExit*(
  cp: ChildProcess, listener: (proc(code: cint, signal: cstring): void)
): ChildProcess {.importcpp: "#.on(\"exit\",@)", discardable.}

proc onClose*(
  cp: ChildProcess, listener: (proc(code: cint, signal: cstring): void)
): ChildProcess {.importcpp: "#.on(\"close\",@)", discardable.}

# StreamReadable
proc onData*(
  ws: StreamReadable, listener: (proc(data: Buffer): void)
): ChildProcess {.importcpp: "#.on(\"data\",@)", discardable.}

proc onceData*(
  ws: StreamReadable, listener: (proc(data: Buffer): void)
): ChildProcess {.importcpp: "#.once(\"data\",@)", discardable.}

var cp*: ChildProcessModule = require("child_process").to(ChildProcessModule)
