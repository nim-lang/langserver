# Nim Language Server

`nimlangserver` is a language server for Nim. It can run in two modes:

- **[LSP server](./lsp.md)** — provides Nim language intelligence to editors and IDEs (VSCode, Neovim, Helix, Emacs, and more).
- **[MCP server](./mcp.md)** — exposes Nim-aware tools to AI coding agents (GitHub Copilot, Claude Code, Gemini, and more).

LSP is the default mode. Running `nimlangserver` is equivalent to `nimlangserver --lsp`.

## Installation

`nimlangserver` requires Nim >= 1.6.8 and nimble >= 0.16.1.

### From Nimble (recommended)

Install the latest release into `$HOME/.nimble/bin`:

```sh
nimble install -g nimlangserver
```

### From source

Clone the repository, then install:

```bash
nimble install -g
```

Or build the binary without installing it:

```bash
nimble build
```

```admonish tip title="Windows users"
Set up your development environment in [WSL](https://learn.microsoft.com/en-us/windows/wsl/) — clone and edit your projects inside the WSL file system.

If you use VSCode, use it with the [WSL extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-wsl). Run terminal-based editors like Neovim or Helix directly in the WSL shell.

Even though `nimlangserver` works on native Windows, you will get better performance and stability in WSL mode.
```

Once installed, connect your editor by following the [LSP server](./lsp.md) setup instructions, or give your AI coding agent semantic Nim understanding by following the [MCP server](./mcp.md) setup instructions.
