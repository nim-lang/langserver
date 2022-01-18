import
  json, os, streams, asyncdispatch, locks, asynctools/asyncpipe,
  langserver/[base_protocol, commands]


import
  json_rpc/streamconnection

let input = asyncWrap(stdout.getFileHandle(), stdin.getFileHandle());

let connection = StreamConnection.new(input, input);

waitFor connection.start();
