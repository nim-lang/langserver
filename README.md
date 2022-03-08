# Nim Language Server

Nim Language Server, or `nimls`, is a language server for Nim.

<!-- omit in toc -->
## Table Of Contents

- [Installation](#installation)
  - [Build Options](#build-options)
  - [Configuration Options](#configuration-options)
- [Usage](#usage)
  - [VSCode](#vscode)
  - [Sublime Text](#sublime-text)
  - [Kate](#kate)
  - [Neovim/Vim8](#neovimvim8)
  - [Emacs](#emacs)
  - [Doom Emacs](#doom-emacs)
- [Related Projects](#related-projects)
- [License](#license)

## Installation

TBA

See [Downloading and Building ZLS](https://github.com/zigtools/zls/wiki/Downloading-and-Building-ZLS) on the Wiki, or the page about [using ZLS with Visual Studio Code](https://github.com/zigtools/zls/wiki/Installing-for-Visual-Studio-Code) for a guide to help get `zls` running in your editor.

### Installing binaries

#### MacOS

You can install the latest release into `$HOME/zls` using e.g.:

```sh
brew install xz
mkdir $HOME/zls && cd $HOME/zls && curl -L https://github.com/zigtools/zls/releases/download/0.9.0/x86_64-macos.tar.xz | tar -xJ --strip-components=1 -C .
```

#### Linux

You can install the latest release into `$HOME/zls` using e.g.:

```
sudo apt install xz-utils
mkdir $HOME/zls && cd $HOME/zls && curl -L https://github.com/zigtools/zls/releases/download/0.9.0/x86_64-linux.tar.xz | tar -xJ --strip-components=1 -C .
```

### From Source

```bash
nimble build
```

*For detailed building instructions, see the Wiki page about [Cloning With Git](https://github.com/zigtools/zls/wiki/Downloading-and-Building-ZLS#cloning-with-git).*

### Configuration Options

TBA

## Features

`nimls` supports most language features, including simple type function support, usingnamespace, payload capture type resolution, custom packages and others.

The following LSP features are supported:
- Completions
- Hover
- Goto definition
- Document symbols
- Find references

You can install `nimls` using the instuctions for your text editor below:

### VSCode

Install the `vscode-nim` extension from [here](https://github.com/saem/vscode-nim)

### Emacs

- Install [lsp-mode](https://github.com/emacs-lsp/lsp-mode) and `nim-mode` from
  melpa and add the following to your config:

``` elisp
(add-hook 'nim-mode-hook 'lsp)
```

## Related Projects

- [nimlsp](https://github.com/PMunch/nimlsp)
  - Supports basic language features
  - Uses data provided by `src/data` to perform builtin autocompletion

## License

MIT
