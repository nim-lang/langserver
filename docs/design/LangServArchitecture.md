This is a short description of the internal workings of the Nim Language
Server (or NLS for short)

## I/O Handling

The language server will operate as a relatively thin proxy between a single
text editor and multiple long-running `nimsuggest` processes (one instance
of `nimsuggest` per project).

When a source file is opened, NLS first uses `nim info` to obtain information
about the owning project of the file (see [Project Discoverability](#project-discoverability)).
ni
> `nim info` is currently an undocumented feature of the compiler under the
  name `nim dump`.

For each unique project/configuration pair, NLS will launch a separate instance
of `nimsuggest` that will be responsible for answering queries about all files
belonging to the project. All queries coming from the editor are handled in
an asynchronous way from a single main thread that relies on asynchronous I/O
when communicating with the `nimsuggest` instances.

> To avoid issues with async `stdin` handling, the stream of JSON-RPC requests
  coming from the editor is currently handled in a separate thread. All requests
  are immediately sent to the main processing thead through an `AsyncPipe`. The
  `stdout` responses are produced by the main thread.

## JSON-RPC Processing

The JSON-RPC calls are dispatched to their handlers through the [`json_rpc]`[1]
library.

[1]: https://github.com/status-im/nim-json-rpc

## File editing

One of the main responsibilities of NLS is replicating the file editing operations
sent by the editor. If there are dirty files, the in-memory contents are written
to a temporary location in the file system before being passed to `nimsuggest`
using the `dirtyFile` switch.

## Logging

The user should be able to trouble-shoot a misbehavior of `nls` by inspecting a
global log file (or perhaps a database). Some filtering capabilities may be required
in order to isolate the requests coming from a particular editor or a particular file.

--------------

Other considerations:

## Installation

The text editor plugins should attempt to locate the `nls` executable. If this
fails, they should offer to install it by running `nimble install langserver`.
If `nimble` cannot be located as well, some appropriate error message should be
displayed.

## Project discoverability

This will be handled by `nim info`. It works by locating the nearest `nims`,
`nimble` or `cfg` file by going up the directory tree of the opened file.
If a main project file is not located, the opened file is assumed to be a
main project file. One challenge is handling include files which are usually
invalid on their own (outside of the context where they are included). We
will work towards solving this issue upstream in Nim.

## Thin mode

Thin mode introduces double indirection and attempts to allow multiple editors
to share a single `nimsuggest` instance per project. Each editor instance still
launches a separate `nls` process, but this process just forwards all commands
to a single master `nls` process that is responsible for managing the actual
`nimsuggest` instances. The slave processes are still responsible for tracking
the in-memory state of the files manipulated in the editor.
