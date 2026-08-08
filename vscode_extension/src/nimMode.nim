## this correspondes to the language mode for nim, better syntax highlighting
## support for nims, nimble, cfg, fitlers, etc... will require this list to
## grow and we'll need to support defaults.

import platform/vscodeApi

var mode*: VscodeDocumentFilter = VscodeDocumentFilter{language: "nim", scheme: "file"}
