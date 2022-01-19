import
  json_rpc/streamconnection,
  streams,
  faststreams/async_backend,
  faststreams/inputs,
  faststreams/outputs,
  faststreams/asynctools_adapters


var pipe = createPipe(register = false)

proc serverThreadStart(pipe: AsyncPipe) {.thread.} =
  var output = asyncPipeOutput(pipe);
  let inputStream = newFileStream(stdin)
  var ch = inputStream.readChar();
  while ch != '\0':
    output.write(ch)
    ch = inputStream.readChar();

var stdioThread: Thread[AsyncPipe]
createThread(stdioThread, serverThreadStart, pipe)

proc echo(params: JsonNode): Future[RpcResult] {.async,
    raises: [CatchableError, Exception].} =
  echo "|||||"
  return some(StringOfJson($params))

let connection = StreamConnection.new(asyncPipeInput(pipe),
                                      Async(fileOutput(stdout)));
connection.register("echo", echo)

joinThread(stdioThread)
# echo "Exit"
