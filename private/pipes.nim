import
  os, asyncdispatch, asynctools/asyncpipe, ranges/ptr_arith

export
  asyncpipe

when defined(windows):
  import winlean

  proc writeToPipe(p: AsyncPipe, data: pointer, nbytes: int) =
    if WriteFile(p.getWriteHandle, data, int32(nbytes), nil, nil) == 0:
      raiseOsError(osLastError())

else:
  import posix

  proc writeToPipe(p: AsyncPipe, data: pointer, nbytes: int) =
    if posix.write(p.getWriteHandle, data, cint(nbytes)) < 0:
      raiseOsError(osLastError())

proc writePipeFrame*(p: AsyncPipe, data: string) =
  var dataLen = data.len
  p.writeToPipe(addr(dataLen), sizeof(dataLen))
  p.writeToPipe(data.baseAddr, data.len)

proc readPipeFrame*(p: AsyncPipe): Future[string] {.async.} =
  var frameSize: int
  var bytesRead = await p.readInto(addr(frameSize), sizeof(frameSize))
  if bytesRead != sizeof(frameSize):
    raiseOsError(osLastError())

  result = newString(frameSize)

  bytesRead = await p.readInto(result.baseAddr, frameSize)
  if bytesRead != frameSize:
    raiseOsError(osLastError())

