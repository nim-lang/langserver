# Nim Language Server

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/nim-lang/langserver)

`nimlangserver` is a language server for Nim. It can run as an **LSP server** for editors and IDEs, or as an **MCP server** for AI coding agents such as GitHub Copilot, Claude Code, and Gemini.

**[Read the docs →](https://nim-lang.github.io/langserver)**

## Quick install

```sh
nimble install -g nimlangserver
```

Requires `nimble >= 0.16.1` and a `nimsuggest` that supports `--v3` (Nim 1.6+ or devel).

## Related projects

- [nimlsp](https://github.com/PMunch/nimlsp) — an alternative Nim language server with `nimsuggest` embedded directly in the binary.

## License

MIT
