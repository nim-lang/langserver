# Nim Language Server

Nim Language Server, or `nimlangserver`, is a language server for Nim.

## Installation

### Installing binaries

You can install the latest release into `$HOME/.nimble/bin` using e.g.:

```sh
nimble install nimlangserver
```

### From Source

```bash
nimble build
```

## Configuration Options

- `nim.rootConfig` - configure how `nimsuggest` should be started. Below, you
  can see a sample configuration for VS Code. We don't want `nimlangserver` to
  start `nimsuggest` for each file and this configuration specifies a number of
  `root`/`regexps` pairs, such that when one of the regexp in the list matches
  the current file then `nimlangserver` will reuse the `nimsuggest` instance
  started for the given `root` module.

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

`nimlangserver` supports the following LSP features:

- Completions
- Hover
- Goto definition
- Document symbols
- Find references

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
   crashes more gracefully and enables it to work with multiple versions of Nim
   concurrently.

## License

MIT
