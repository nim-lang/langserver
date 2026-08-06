## nimble_types.nim
## Standalone type definitions for nimble dump results.
## Kept in a separate file so both langserver_types.nim and nimble.nim can import
## it without creating a circular dependency.

import std/options

type
  NimbleDumpInfo* = object
    srcDir*: string
    name*: string
    nimDir*: Option[string]
    nimblePath*: Option[string]
    entryPoints*: seq[string] ## when it's empty, means the nimble version doesn't dump it.
