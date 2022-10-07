# Nim Language Server

Nim Language Server, or `nimlangserver`, is a language server for Nim.

## Installation
### VSCode
- [vscode-nim](https://github.com/saem/vscode-nim) has support for `nimlangserver`. Follow the instructions at:
https://github.com/saem/vscode-nim#nim-lanugage-server-integration-experimental

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

You can install `nimlangserver` using the instuctions for your text editor below:

### VSCode

Install the `vscode-nim` extension from [here](https://github.com/saem/vscode-nim)

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
