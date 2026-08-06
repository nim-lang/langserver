import std/[os]

# unicode, uri, strformat, os, strutils, options, json, jsonutils, sugar, net, hashes]
# import with
import chronos, chronicles, chronos/asyncproc
import "$nim/compiler/pathutils"
import json_rpc/private/jrpc_sys
import macros
import stew/byteutils

# import ../nim_tools/nimsuggest/nimsuggest_types
import ../protocol/types

proc shutdownChildProcess*(p: AsyncProcessRef): Future[void] {.async.} =
  try:
    debug "Shutting down process with pid: ", pid = p.processID()
    let exitCode = await p.terminateAndWaitForExit(2.seconds)
      # debug "Process terminated with exit code: ", exitCode
  except CatchableError:
    try:
      let forcedExitCode = await p.killAndWaitForExit(3.seconds)
      debug "Process forcibly killed with exit code: ", exitCode = forcedExitCode
    except CatchableError:
      debug "Could not kill process in time either!"
      writeStackTrace()

proc catchOrQuit*(error: Exception) =
  if error of CatchableError:
    trace "Async operation ended with a recoverable error", err = error.msg
  else:
    fatal "Fatal exception reached", err = error.msg, stackTrace = getStackTrace()
    quit 1

proc traceAsyncErrors*(fut: Future) =
  fut.addCallback do(data: pointer):
    if not fut.error.isNil:
      catchOrQuit fut.error[]


#Compatibility layer with asyncdispatch
proc callSoon*(cb: proc() {.gcsafe.}) {.gcsafe.} =
  proc cbWrapper() {.gcsafe.} =
    try:
      {.cast(raises: []).}:
        cb()
    except CatchableError:
      discard #TODO handle

  callSoon do(data: pointer) {.gcsafe.}:
    cbWrapper()

proc addCallback*(
    future: FutureBase, cb: proc() {.closure, gcsafe, raises: [].}
) {.deprecated: "Replace with built-in chronos mechanism".} =
  ## Adds the callbacks proc to be called when the future completes.
  ##
  ## If future has already completed then `cb` will be called immediately.
  assert cb != nil
  if future.finished:
    callSoon do(data: pointer) {.gcsafe.}:
      cb()
  else:
    future.addCallback do(data: pointer) {.gcsafe.}:
      cb()

proc addCallbackNoEffects[T](
    future: Future[T], cb: proc(future: Future[T]) {.closure, gcsafe, raises: [].}
) =
  ## Adds the callbacks proc to be called when the future completes.
  ##
  ## If future has already completed then `cb` will be called immediately.
  future.addCallback(
    proc() =
      cb(future)
  )

proc addCallback*[T](
    future: Future[T], cb: proc(future: Future[T]) {.closure, gcsafe.}
) {.deprecated.} =
  ## Adds the callbacks proc to be called when the future completes.
  ##
  ## If future has already completed then `cb` will be called immediately.
  proc cbWrapper(fut: Future[T]) {.closure, gcsafe, raises: [].} =
    try:
      {.cast(raises: []).}:
        cb(fut)
    except CatchableError as exc:
      future.fail((ref CatchableError)(msg: exc.msg))

  future.addCallbackNoEffects(
    proc(fut: Future[T]) {.closure, gcsafe, raises: [].} =
      cbWrapper(future)
  )

proc withTimeout*[T](fut: Future[T], timeout: int = 500): Future[Option[T]] {.async.} =
  #Returns None when the timeout is reached and cancels the fut. Otherwise returns the Fut
  let timeoutFut = sleepAsync(timeout).map(() => none(T))
  let optFut = fut.map((r: T) => some r)
  await either(optFut, timeoutFut)

proc getNextFreePort*(): Port =
  let s = newSocket()
  s.bindAddr(Port(0), "localhost")
  let (_, port) = s.getLocalAddr
  s.close()
  port


proc readAllOutput*(stream: AsyncStreamReader): Future[string] {.async.} =
  result = ""
  while not stream.atEof:
    let data = await stream.read()
    result.add(string.fromBytes(data))

proc readErrorOutputUntilExit*(
    process: AsyncProcessRef, duration: Duration
): Future[tuple[output: string, code: int]] {.async.} =
  var output = ""
  var res = 0
  while true:
    if not process.stderrStream.atEof:
      let data = await process.stderrStream.read()
      output.add(string.fromBytes(data))

    let hasExited =
      try:
        res = await process.waitForExit(duration)
        true
      except AsyncTimeoutError:
        false

    if hasExited:
      while not process.stderrStream.atEof:
        let data = await process.stderrStream.read()
        output.add(string.fromBytes(data))
      return (output, res)

proc readOutputUntilExit*(
    process: AsyncProcessRef, duration: Duration
): Future[tuple[output: string, error: string, code: int]] {.async.} =
  var output = ""
  var error = ""
  var res = 0
  # debug "Starting read output until exit"

  while true:
    let hasExited =
      try:
        res = await process.waitForExit(duration)
        debug "Process exit check", hasExited = true, res = res
        true
      except AsyncTimeoutError:
        debug "Process still running"
        false

    # Quick non-blocking reads
    try:
      if not process.stdoutStream.atEof:
        # debug "Attempting stdout read"
        let data = await process.stdoutStream.read() #
        if data.len > 0:
          # debug "Got stdout data", len = data.len
          output.add(string.fromBytes(data))
    except CatchableError as e:
      debug "Stdout read error", msg = e.msg

    try:
      if not process.stderrStream.atEof:
        # debug "Attempting stderr read"
        let data = await process.stderrStream.read()
        if data.len > 0:
          # debug "Got stderr data", len = data.len
          error.add(string.fromBytes(data))
    except CatchableError as e:
      debug "Stderr read error", msg = e.msg

    if hasExited:
      # debug "Process has exited, final cleanup", output = output, error = error, code = res
      return (output, error, res)
