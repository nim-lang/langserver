## provides a list of symbols and documents so vscode can use them for search
## results when you do symbol or document search.

import platform/vscodeApi
import nimIndexer

proc provideWorkspaceSymbols(
    query: cstring, token: VscodeCancellationToken
): Promise[seq[VscodeSymbolInformation]] =
  return findWorkspaceSymbols(query)

proc provideDocumentSymbols(
    doc: VscodeTextDocument, token: VscodeCancellationToken
): Promise[seq[VscodeDocumentSymbol]] =
  return getDocumentSymbols(doc.filename, true, doc.getText())

type NimOutline* = ref object
  provideWorkspaceSymbols*: proc(query: cstring, token: VscodeCancellationToken)
  provideDocumentSymbols*: proc(doc: VscodeTextDocument, token: VscodeCancellationToken)

var nimSymbolProvider* {.exportc.} = block:
  var o = newJsObject()
  o.provideWorkspaceSymbols = provideWorkspaceSymbols
  o.provideDocumentSymbols = provideDocumentSymbols
  o

var nimDocSymbolProvider* {.exportc.} =
  nimSymbolProvider.to(VscodeDocumentSymbolProvider)
var nimWsSymbolProvider* {.exportc.} =
  nimSymbolProvider.to(VscodeWorkspaceSymbolProvider)
