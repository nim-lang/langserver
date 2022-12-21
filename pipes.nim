import faststreams/asynctools_adapters, streams, os

when defined(windows):
  import winlean

  proc writeToPipe*(p: AsyncPipe, data: pointer, nbytes: int) =
    if writeFile(p.getWriteHandle, data, int32(nbytes), nil, nil) == 0:
      raiseOsError(osLastError())

else:
  import posix

  proc writeToPipe*(p: AsyncPipe, data: pointer, nbytes: int) =
    if posix.write(p.getWriteHandle, data, cint(nbytes)) < 0:
      raiseOsError(osLastError())

proc copyFileToPipe*(param: tuple[pipe: AsyncPipe, file: File]) {.thread.} =
  var
    inputStream = newFileStream(param.file)
    ch = "^"

  ch[0] = inputStream.readChar()

  while ch[0] != '\0':
    writeToPipe(param.pipe, ch[0].addr, 1)
    ch[0] = inputStream.readChar();
  closeWrite(param.pipe, false)
