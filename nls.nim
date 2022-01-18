import
  json, asyncdispatch, json_rpc/streamconnection,
  faststreams/async_backend,
  faststreams/inputs,
  faststreams/outputs,
  faststreams/asynctools_adapters

proc echo(params: JsonNode): Future[RpcResult] {.async,
    raises: [CatchableError, Exception].} =
  echo "XXXXX"
  return some(StringOfJson($params))

# let a = stdin.getFileHandle()
# echo a

# let input = fileInput(system.stdin)
# let output = fileOutput(system.stdout)

# let aas = Async(fileInput(stdin));
let inputStream = Async(fileInput(stdin).s)
let outputStream = Async(fileOutput(stdout).s)

let connection = StreamConnection.new(inputStream, outputStream);
connection.register("echo", echo)
waitFor connection.start();
