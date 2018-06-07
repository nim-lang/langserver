import
  json, os, streams, asyncdispatch, locks,
  asynctools/[asyncpipe, asyncproc],
  private/pipes, langserver/[base_protocol, commands]

var
  userInputPipe = createPipe(register = false)
  userInputPipeIn = userInputPipe.getReadHandle
  userInputPipeOut = userInputPipe.getWriteHandle

var
  framesToProcess = 0
  L: Lock
  C: Cond

initCond(C)
initLock(L)

proc nimsuggestThreadStart() {.thread.} =
  var userInput = asyncWrap(userInputPipeIn,
                            userInputPipeOut)

  var log = open("/tmp/nls.log", fmWrite)

  while true:
    withLock L:
      let frame = waitFor userInput.readPipeFrame
      let frameCmd = parseJson(frame)
      log.writeLine "frame: ", frameCmd
      dec framesToProcess
    sleep 0
    signal C

var nimsuggestThread: Thread[void]
createThread(nimsuggestThread, nimsuggestThreadStart)

var s = newFileStream(stdin)
while true:
  try:
    let frame = s.readFrame
    withLock L:
      inc framesToProcess
      userInputPipe.writePipeFrame(frame)
  except IOError:
    while framesToProcess > 0:
      wait C, L
    break

