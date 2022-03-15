# Nim Language Server

Nim Language Server, or `nimls`, is a language server for Nim.

## Installation

### Installing binaries

You can install the latest release into `$HOME/.nimble/bin` using e.g.:

```sh
nimble install https://github.com/nim-lang/langserver
```

### From Source

```bash
nimble build
```

### Configuration Options

- `nim.rootConfig` - configure how `nimsuggest` should be started. Here it is
  sample configuration for `VScode`. We don't want `nimls` to start `nimsuggest`
  for each file and this configuration will allow configuring pair
  `root`/`regexps` so when one of the regexp in the list matches current file
  then `nimls` will use `root` to start `nimsuggest`.

``` json
{
    "nim.rootConfig": [{
        // open files under tests using one nimsuggest instance started with root = test/all.nim
        "root": "tests/all.nim",
        "regexps": [
            "tests/.*\\.nim"
        ]
    }, {
        // everything else - use main.nim as root.
        "root": "main.nim",
        "regexps": [
            ".*\\.nim"
        ]
    }]
}
```

## Features

`nimls` the following LSP features are supported:
- Completions
- Hover
- Goto definition
- Document symbols
- Find references

You can install `nimls` using the instuctions for your text editor below:

### VSCode

Install the `vscode-nim` extension from [here](https://github.com/saem/vscode-nim)

### Emacs

- Install [lsp-mode](https://github.com/emacs-lsp/lsp-mode) and `nim-mode` from melpa and add the following to your
  config:

``` elisp
(add-hook 'nim-mode-hook #'lsp)
```

## Related Projects

- [nimlsp](https://github.com/PMunch/nimlsp) Similarly to `nimls` it uses
  `nimsuggest` but in `nimls` case `nimsuggest` is started as external process
  and as a result `nimsuggest` crashes don't result in `nimls` crash.


## License

MIT
