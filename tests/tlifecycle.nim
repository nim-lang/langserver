import
  std/[json, os, strformat, net],
  chronos,
  chronos/[asyncproc, osutils],
  unittest2,
  ../utils,
  ./lspsocketclient

when defined(windows):
  import chronos/osdefs

const
  CRLF = "\r\n"
  ServerSource = "nimlangserver.nim"
  ServerBinary = "tests" / "nimlangserver_lifecycle".addFileExt(ExeExt)
  SigSegv = 128 + 11

proc frame(msg: JsonNode): string =
  let body = $msg
  &"Content-Length: {body.len}{CRLF}{CRLF}{body}"

proc initializeMsg(rootUri: JsonNode, pullConfiguration: bool): JsonNode =
  let capabilities =
    if pullConfiguration:
      %*{"workspace": {"configuration": true}}
    else:
      newJObject()
  %*{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "processId": newJNull(),
      "rootUri": rootUri,
      "workspaceFolders": newJNull(),
      "capabilities": capabilities,
    },
  }

type Server = object
  process: AsyncProcessRef
  input: StreamTransport

# XXX use this instead after https://github.com/status-im/nim-chronos/pull/729
#proc startServer(args: seq[string]): AsyncProcessRef =
#  waitFor startProcess(
#    ServerBinary.absolutePath, arguments = args, stdinHandle = AsyncProcess.Pipe
#  )
#
#proc send(p: AsyncProcessRef, data: string) =
#  waitFor p.stdinStream.write(data)

proc closePipeEnd(fd: AsyncFD) =
  when defined(windows):
    discard closeFd(HANDLE(fd))
  else:
    discard closeFd(cint(fd))

proc startServer(args: seq[string]): Server =
  const
    theirEnd = {DescriptorFlag.NonBlock}
    ourEnd = {DescriptorFlag.NonBlock, DescriptorFlag.CloseOnExec}
  let pipe = createOsPipe(theirEnd, ourEnd).valueOr:
    raiseAssert "Unable to create the server's standard input pipe"

  result.input = fromPipe(AsyncFD(pipe.write))
  result.process = waitFor startProcess(
    ServerBinary.absolutePath,
    arguments = args,
    stdinHandle = ProcessStreamHandle.init(AsyncFD(pipe.read)),
  )
  closePipeEnd(AsyncFD(pipe.read))

proc send(s: Server, data: string) =
  discard waitFor s.input.write(data)

proc closeStdin(s: Server) =
  waitFor s.input.closeWait()

proc exitCodeWithin(s: Server, timeout: Duration): int =
  let exiting = s.process.waitForExit(InfiniteDuration)
  result =
    if waitFor exiting.withTimeout(timeout):
      exiting.read()
    else:
      discard s.process.kill()
      discard waitFor s.process.waitForExit(InfiniteDuration)
      -1
  waitFor s.input.closeWait()
  waitFor s.process.closeWait()

suite "Nimlangserver process lifecycle":
  # Required for the rest of the tests
  test "the server binary has been built":
    let res =
      waitFor execCommandEx(&"nim c --hints:off -o:{ServerBinary} {ServerSource}")
    if res.status != 0:
      checkpoint "nimlangserver build output: " & res.stdOutput & res.stdError
      fail()

  test "stdio: closing stdin exits cleanly":
    let p = startServer(@["--stdio"])
    p.send(frame(initializeMsg(%fixtureUri("projects/hw/"), false)))
    waitFor sleepAsync(500.milliseconds)
    p.closeStdin()
    check p.exitCodeWithin(30.seconds) == 0

  test "stdio: the exit notification exits cleanly":
    let p = startServer(@["--stdio"])
    p.send(frame(initializeMsg(%fixtureUri("projects/hw/"), false)))
    waitFor sleepAsync(500.milliseconds)
    p.send(frame(%*{"jsonrpc": "2.0", "id": 2, "method": "shutdown"}))
    p.send(frame(%*{"jsonrpc": "2.0", "method": "exit"}))
    check p.exitCodeWithin(30.seconds) == 0

  test "stdio: a malformed frame is reported as a failure":
    let p = startServer(@["--stdio"])
    p.send(&"Content-Length: -5{CRLF}{CRLF}xxxxx")
    p.closeStdin()
    check p.exitCodeWithin(30.seconds) == 1

  test "stdio: a body shorter than the declared length ends the session":
    let p = startServer(@["--stdio"])
    let body = """{"jsonrpc":"2.0","id":1,"method":"shutdown"}"""
    p.send(&"Content-Length: 500{CRLF}{CRLF}{body}")
    p.closeStdin()
    check p.exitCodeWithin(30.seconds) == 0

  test "stdio: leaving with a request pending does not crash the server":
    let p = startServer(@["--stdio"])
    p.send(frame(initializeMsg(%fixtureUri("projects/hw/"), true)))
    p.send(frame(%*{"jsonrpc": "2.0", "method": "initialized"}))
    waitFor sleepAsync(1500.milliseconds)
    p.closeStdin()

    let code = p.exitCodeWithin(60.seconds)
    check code != SigSegv
    check code == 0

  test "socket: leaving with a request pending does not crash the server":
    let port = getNextFreePort()
    let p = startServer(@["--socket", &"--port={port.int}"])
    waitFor sleepAsync(1.seconds)
    var socket = newSocket()
    socket.connect("localhost", port)
    socket.send(frame(initializeMsg(%fixtureUri("projects/hw/"), true)))
    socket.send(frame(%*{"jsonrpc": "2.0", "method": "initialized"}))
    waitFor sleepAsync(1500.milliseconds)
    socket.close()

    let code = p.exitCodeWithin(60.seconds)
    check code != SigSegv
