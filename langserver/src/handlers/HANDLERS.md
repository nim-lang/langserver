# Request handlers (response required)

| LSP Method | Input | Output |
|---|---|---|
| `initialize` | `LspInitializeParams` | `LspInitializeResult` |
| `shutdown` | `JsonNode` | `JsonNode` |
| `exit` | `JsonNode` | `JsonNode` |
| `textDocument/completion` | `CompletionParams` | `seq[CompletionItem]` |
| `textDocument/definition` | `TextDocumentPositionParams` | `seq[Location]` |
| `textDocument/declaration` | `TextDocumentPositionParams` | `seq[Location]` |
| `textDocument/typeDefinition` | `TextDocumentPositionParams` | `seq[Location]` |
| `textDocument/documentSymbol` | `DocumentSymbolParams` | `seq[SymbolInformation]` |
| `textDocument/hover` | `HoverParams` | `Option[Hover]` |
| `textDocument/references` | `ReferenceParams` | `seq[Location]` |
| `textDocument/prepareRename` | `PrepareRenameParams` | `JsonNode` |
| `textDocument/rename` | `RenameParams` | `WorkspaceEdit` |
| `textDocument/inlayHint` | `InlayHintParams` | `seq[InlayHint]` |
| `textDocument/signatureHelp` | `SignatureHelpParams` | `Option[SignatureHelp]` |
| `textDocument/formatting` | `DocumentFormattingParams` | `seq[TextEdit]` |
| `textDocument/documentHighlight` | `TextDocumentPositionParams` | `seq[DocumentHighlight]` |
| `textDocument/codeAction` | `CodeActionParams` | `seq[CodeAction]` |
| `workspace/executeCommand` | `ExecuteCommandParams` | `JsonNode` |
| `workspace/symbol` | `WorkspaceSymbolParams` | `seq[SymbolInformation]` |
| `extension/macroExpand` | `ExpandTextDocumentPositionParams` | `ExpandResult` |
| `extension/status` | `NimLangServerStatusParams` | `NimLangServerStatus` |
| `extension/capabilities` | `JsonNode` | `seq[string]` |
| `extension/suggest` | `SuggestParams` | `SuggestResult` |
| `extension/tasks` | `JsonNode` | `seq[NimbleTask]` |
| `extension/runTask` | `RunTaskParams` | `RunTaskResult` |
| `extension/listTests` | `ListTestsParams` | `ListTestsResult` |
| `extension/runTests` | `RunTestParams` | `RunTestProjectResult` |
| `extension/cancelTest` | `JsonNode` | `CancelTestResult` |

---

# Notification handlers (no response)

| LSP Method | Input | Output |
|---|---|---|
| `initialized` | `JsonNode` | `void` |
| `$/cancelRequest` | `CancelParams` | `void` |
| `$/setTrace` | `SetTraceParams` | `void` |
| `textDocument/didChange` | `DidChangeTextDocumentParams` | `void` |
| `textDocument/willSaveWaitUntil` | `WillSaveTextDocumentParams` | `seq[TextEdit]` |
| `textDocument/didSave` | `DidSaveTextDocumentParams` | `void` |
| `textDocument/didClose` | `DidCloseTextDocumentParams` | `void` |
| `textDocument/didOpen` | `DidOpenTextDocumentParams` | `void` |
| `workspace/didRenameFiles` | `RenameFilesParams` | `void` |
| `workspace/didDeleteFiles` | `DeleteFilesParams` | `void` |
| `workspace/didChangeConfiguration` | `JsonNode` | `void` |
