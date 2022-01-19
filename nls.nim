import
  json, asyncdispatch, json_rpc/streamconnection, os,
  streams,
  faststreams/async_backend,
  faststreams/inputs,
  faststreams/textio,
  faststreams/outputs,
  faststreams/asynctools_adapters


proc echo(params: JsonNode): Future[RpcResult] {.async,
    raises: [CatchableError, Exception].} =
  echo "|||||"
  return some(StringOfJson($params))

var
  pipe = createPipe(register = false)
  userInputPipeIn = pipe.getReadHandle
  userInputPipeOut = pipe.getWriteHandle

var
  userInputPipe = createPipe(register = false)

proc serverThreadStart() {.thread.} =
  let p  = asyncWrap(userInputPipeIn, userInputPipeOut)
  var output = asyncPipeOutput(pipe);
  let inputStream = newFileStream(stdin)
  var ch = inputStream.readChar();
  while ch != '\0':
    output.write(ch)
    ch = inputStream.readChar();

var stdioThread: Thread[void]
createThread(stdioThread, serverThreadStart)

let connection = StreamConnection.new(asyncPipeInput(pipe),
                                      Async(fileOutput(stdout)));
connection.register("echo", echo)

joinThread(stdioThread)
echo "Exit"
