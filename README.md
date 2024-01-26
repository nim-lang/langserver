# Nim Language Server

Nim Language Server, or `nimlangserver`, is a language server for Nim.

## Installation
### VSCode
- [vscode-nim](https://github.com/nim-lang/vscode-nim) has support for `nimlangserver`. Follow the instructions at:
https://github.com/nim-lang/vscode-nim#using

### Neovim
- [lsp](https://neovim.io/doc/user/lsp.html) Neovim has built-in LSP support. Although, you might want to use something like [lsp-config](https://github.com/neovim/nvim-lspconfig) to take care of the boilerplate code for the most LSP configurations. Install `lsp-config` using your favourite plugin manager an place the following code into your `init.vim` config:
```lua
lua <<EOF

require'lspconfig'.nim_langserver.setup{
  settings = {
    nim = {
      nimsuggestPath = "~/.nimble/bin/custom_lang_server_build"
    }
  }
}

EOF
```
Change configuration to your liking (most probably you don't need to provide any settings at all, defaults should work fine for the majority of the users). You might also want to read `lsp-config` documentation to setup key bindings, autocompletion and so on.

**IMPORTANT** you might want to use latest build of the `nimlangserver` and/or build it from source.

### VIM/Neovim
- [coc.nvim](https://github.com/neoclide/coc.nvim) supports both classical VIM as well as Neovim. It also supports vscode-like `coc-settings.json` for LSP configuration. Install the plugin via your favourite plugin manager, create `coc-settings.json` alongside your `init.vim` and add the following contents to it:
```json
{
  "languageserver": {
    "nim": {
      "command": "nimlangserver",
      "filetypes": ["nim"],
      "trace.server": "verbose",
      "settings": {
        "nim": {
          "nimsuggestPath": "~/.nimble/bin/nimsuggest"
        }
      }
    }
  }
}
```
Of course, change the configuration to your liking. You might also want to read `coc.nvim` documentation to setup key bindings, autocompletion and so on.

**IMPORTANT** you might want to use latest build of the `nimlangserver` and/or build it from source.

### Installing binaries

_NB:_ `nimlangserver` requires `nimsuggest` version that supports `--v3`:
- `devel` containing [19826](https://github.com/nim-lang/Nim/pull/19826)
- 1.6+ containing [19892](https://github.com/nim-lang/Nim/pull/19892)

You can install the latest release into `$HOME/.nimble/bin` using e.g.:

```sh
nimble install nimlangserver
```

### From Source

```bash
nimble build
```

## Configuration Options

- `nim.projectMapping` - configure how `nimsuggest` should be started. Here it is sample configuration for `VScode`. We don't want `nimlangserver` to start `nimsuggest` for each file and this configuration will allow configuring pair `projectPath`/`fileRegex` so when one of the regexp in the list matches current file
  then `nimls` will use `root` to start `nimsuggest`. In case there are no matches `nimlangserver` will try to guess the most suitable project root.
- `nim.timeout` - the request timeout in ms after which `nimlangserver` will restart the language server. If not specified the default is 2 minutes.
- `nim.nimsuggestPath` - the path to the `nimsuggest`. The default is `"nimsuggest"`.
- `nim.autoCheckFile` - check the file on the fly
- `nim.autoCheckProject` - check the project after saving the file
- `nim.autoRestart` - auto restart once in case of `nimsuggest` crash. Note that
  the server won't restart if there weren't any successful calls after the last
  restart.

``` json
{
    "nim.projectMapping": [{
        // open files under tests using one nimsuggest instance started with root = test/all.nim
        "projectPath": "tests/all.nim",
        "fileRegex": "tests/.*\\.nim"
    }, {
        // everything else - use main.nim as root.
        "projectPath": "main.nim",
        "fileRegex": ".*\\.nim"
    }]
}
```

## Features

`nimlangserver` supports the following LSP features:

- Completions
- Hover
- Goto definition
- Document symbols
- Find references
- Workspace symbols
- Rename symbols
- Inlay hints

You can install `nimlangserver` using the instructions for your text editor below:

### Extension methods
In addition to the standard `LSP` methods, `nimlangserver` provides additional nim specific methods.

### `extension/macroExpand`

* Request:
```nim
type
  ExpandTextDocumentPositionParams* = ref object of RootObj
    textDocument*: TextDocumentIdentifier
    position*: Position
    level*: Option[int]
```
Where:
- `position` is the position in the document.
- `textDocument` is the document.
- `level` is the how much levels to expand from the current position

* Response:
``` nim
type
  ExpandResult* = ref object of RootObj
    range*: Range
    content*: string
```
Where:
- `content` is the expand result
- `range` is the original range of the request.

Here it is sample request/response:

```
[Trace - 11:10:09 AM] Sending request 'extension/macroExpand - (141)'.
Params: {
  "textDocument": {
    "uri": "file:///.../tests/projects/hw/hw.nim"
  },
  "position": {
    "line": 27,
    "character": 2
  },
  "level": 1
}


[Trace - 11:10:10 AM] Received response 'extension/macroExpand - (141)' in 309ms.
Result: {
  "range": {
    "start": {
      "line": 27,
      "character": 0
    },
    "end": {
      "line": 28,
      "character": 19
    }
  },
  "content": "  block:\n    template field1(): untyped =\n      a.field1\n\n    template field2(): untyped =\n      a.field2\n\n    field1 = field2"
}

```

### VSCode

Install the `vscode-nim` extension from [here](https://github.com/nim-lang/vscode-nim)

### Emacs

- Install [lsp-mode](https://github.com/emacs-lsp/lsp-mode) and `nim-mode` from melpa and add the following to your
  config:

``` elisp
(add-hook 'nim-mode-hook #'lsp)
```

## Related Projects

- [nimlsp](https://github.com/PMunch/nimlsp)

   Both `nimlangserver` and `nimlsp` are based on `nimsuggest`, but the main
   difference is that `nimlsp` has a single specific version of `nimsuggest`
   embedded in the server executable, while `nimlangserver` launches `nimsuggest`
   as an external process. This allows `nimlangserver` to handle any `nimsuggest`
   crashes more gracefully.

## License

MIT
