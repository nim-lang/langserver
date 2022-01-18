import
  json, asyncdispatch, asynctools/asyncpipe,
  json_rpc/streamconnection,
  faststreams/async_backend,
  streams,
  faststreams/inputs,
  faststreams/outputs,
  faststreams/textio,
  faststreams/asynctools_adapters,
  asynctools/asyncpipe

proc echo(params: JsonNode): Future[RpcResult] {.async,
    raises: [CatchableError, Exception].} =
  echo "XXXXX"
  return some(StringOfJson($params))

# let a = stdin.getFileHandle()
# echo a

# let input = fileInput(system.stdin)
# let output = fileOutput(system.stdout)

# let aas = Async(fileInput(stdin));
# let connection = StreamConnection.new(fsStdIn, fsStdOut);
# connection.register("echo", echo)

# # waitFor connection.start();
# # var x = "XXXX"
# # discard waitFor pipe.write(x[0].addr, x.len)
let a = asyncPipeInput(pipe)
echo waitFor a.readLine()
# discard waitFor pipe.readLine()
