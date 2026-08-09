import std/[jsffi, macros]

type
  Array*[T] = ref ArrayObj[T]
  ArrayObj[T] {.importc.} = object of JsRoot

  Map*[K, V] = ref MapObj[K, V]
  MapObj[K, V] {.importc.} = object of JsRoot

  # MapKeyIter*[K,V] = ref MapKeyIterObj[K,V]
  # MapKeyIterObj[K,V] {.importc.} = object of JsRoot

  # MapKeyIterResult*[K] = ref MapKeyIterResultObj[K]
  # MapKeyIterResultObj[K] {.importc.} = object of JsRoot
  #     value*:K
  #     done*:bool
  Buffer* = ref BufferObj
  BufferObj {.importc.} = object of JsRoot
    len* {.importcpp: "length".}: cint

  ProcessModule = ref ProcessModuleObj
  ProcessModuleObj {.importc.} = object of JsRoot
    env*: JsAssoc[cstring, cstring]
    platform*: cstring

  GlobalModule = ref GlobalModuleObj
  GlobalModuleObj {.importc.} = object of JsRoot

  Timeout* = ref object

var process* {.importc, nodecl.}: ProcessModule
var global* {.importc, nodecl.}: GlobalModule

# static
proc newMap*[K, V](): Map[K, V] {.importcpp: "(new Map())".}
proc newArray*[T](size = 0): Array[T] {.importcpp: "(new Array(@))".}
proc newArray*[T](i: T): Array[T] {.importcpp: "(new Array(@))", varargs.}
proc newArrayWith*[T](i: T): Array[T] {.importcpp: "(new Array(@))", varargs.}

proc bufferConcat*(b: Array[Buffer]): Buffer {.importcpp: "(Buffer.concat(@))".}
proc bufferAlloc*(size: cint): Buffer {.importcpp: "(Buffer.alloc(@))".}

# global
proc setInterval*(
  g: GlobalModule, f: proc(): void, t: cint
): Timeout {.importcpp, discardable.}

proc setTimeout*(
  g: GlobalModule, f: proc(): void, t: cint
): Timeout {.importcpp, discardable.}

proc clearInterval*(g: GlobalModule, t: Timeout): void {.importcpp.}

# Array
proc `[]`*[T](a: Array[T], idx: cint): T {.importcpp: "#[#]".}
proc `[]`*[T](a: Array[T], idx: int): T {.importcpp: "#[#]".}
proc `[]=`*[T](a: Array[T], idx: cint, val: T): T {.importcpp: "#[#]=#".}
proc push*[T](a: Array[T], val: T): cint {.discardable, importcpp.}
proc add*[T](a: Array[T], val: T) {.importcpp: "#.push(#)".}
proc pop*[T](a: Array[T]): T {.importcpp.}
proc shift*[T](a: Array[T]): T {.importcpp.}
proc unshift*[T](a: Array[T]): T {.importcpp.}
proc len*[T](a: Array[T]): cint {.importcpp: "#.length".}
proc setLen*[T](a: Array[T], newlen: Natural): void {.importcpp: "#.length = #".}

iterator items*[T](a: Array[T]): T =
  ## Yields the elements in an Array.
  var i: T
  {.emit: "for (let `i` of `a`) {".}
  yield i
  {.emit: "}".}

iterator pairs*[T](a: Array[T]): (cint, T) =
  ## Yields the elements in an Array.
  var k: cint
  var v: T
  {.emit: "for (let [`k`, `v`] of `a`.entries()) {".}
  yield (k, v)
  {.emit: "}".}

# Map
proc `[]`*[K, V](m: Map[K, V], key: K): V {.importcpp: "#.get(@)".}
proc `[]=`*[K, V](m: Map[K, V], key: K, value: V): void {.importcpp: "#.set(@)".}
proc delete*[K, V](m: Map[K, V], key: K): bool {.importcpp, discardable.}
proc clear*[K, V](m: Map[K, V]) {.importcpp.}
proc has*[K, V](m: Map[K, V], key: K): bool {.importcpp.}

iterator keys*[K, V](m: Map[K, V]): K =
  ## Yields the `keys` in a Map.
  var k: K
  {.emit: "for (let `k` of `m`.keys()) {".}
  yield k
  {.emit: "}".}

iterator values*[K, V](m: Map[K, V]): V =
  ## Yields the `keys` in a Map.
  var v: V
  {.emit: "for (let `v` of `m`.values()) {".}
  yield v
  {.emit: "}".}

iterator pairs*[K, V](m: Map[K, V]): (K, V) =
  ## Yields the `entries` in a Map.
  var k: K
  var v: V
  {.emit: "for (let e of `m`.entries()) {".}
  {.emit: "  `k` = e[0]; `v` = e[1];".}
  yield (k, v)
  {.emit: "}".}

iterator entries*[K, V](m: Map[K, V]): (K, V) =
  ## Yields the `entries` in a Map.
  var k: K
  var v: V
  {.emit: "for (let e of `m`.entries()) {".}
  {.emit: "  `k` = e[0]; `v` = e[1];".}
  yield (k, v)
  {.emit: "}".}

# Buffer
proc toString*(b: Buffer): cstring {.importcpp.}
proc toStringBase64*(b: Buffer): cstring {.importcpp: "(#.toString('base64'))".}
proc toStringUtf8*(
  b: Buffer, start: cint, stop: cint
): cstring {.importcpp: "(#.toString('utf8', #, #))".}

proc slice*(b: Buffer, start: cint): Buffer {.importcpp.}

# JSON
proc jsonStringify*[T](val: T): cstring {.importcpp: "JSON.stringify(@)".}
proc toJsonStr(x: NimNode): NimNode {.compileTime.} =
  result = newNimNode(nnkTripleStrLit)
  result.strVal = astGenRepr(x)

template jsonStr*(x: untyped): untyped =
  ## Convert an expression to a JSON string directly, without quote
  result = toJsonStr(x)

proc jsonParse*(val: cstring): JsObject {.importcpp: "JSON.parse(@)".}
proc jsonParse*(val: cstring, T: typedesc): T {.importcpp: "JSON.parse(@)".}

# Misc
var numberMinValue* {.importc: "(Number.MIN_VALUE)", nodecl.}: cdouble
proc isJsArray*(a: JsObject): bool {.importcpp: "(# instanceof Array)".}
