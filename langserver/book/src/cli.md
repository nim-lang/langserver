# Command-Line Reference

You don't normally launch `nimlangserver` by hand — editors and AI tools start it automatically based on their configuration. This page is a reference for when you do need direct control: debugging, socket mode, scripting, or integrating with a tool not covered by the existing configs.

## Synopsis

```
nimlangserver [options]
```

## Options

| Option | Description |
|---|---|
| `--lsp` | Run in LSP server mode. This is the default. |
| `--mcp` | Run in MCP server mode. |
| `--stdio` | Use stdio transport. This is the default for both modes. |
| `--socket` | Use socket transport. |
| `--port=<port>` | Port to listen on when using socket transport. If omitted, a free port is chosen automatically and printed to the console. |
| `--clientProcessId=<pid>` | Exit automatically when the process with the given PID terminates. Editors pass this to tie the server lifetime to their own. |
| `--version`, `-v` | Print version information and exit. |
| `--help`, `-h` | Print a help message and exit. |

## Mode and transport combinations

```bash
nimlangserver                          # LSP over stdio (default)
nimlangserver --lsp --socket           # LSP over socket, auto port
nimlangserver --lsp --socket --port=6000

nimlangserver --mcp                    # MCP over stdio
nimlangserver --mcp --socket           # MCP over socket, auto port
nimlangserver --mcp --socket --port=6001
```

**stdio** is the right choice when the client launches `nimlangserver` as a subprocess (the normal case for both editors and AI agents).

**socket** is useful when the server and client run in separate environments — for example, a native Windows editor connecting to a server running inside WSL, or when you want a single running server to be reachable from multiple clients.
