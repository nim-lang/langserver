# Startup Call Graph

Here's the full startup call graph, tracing through activate() in order:

```
activate() [nimvscode.nim:493]
│
├── Create ExtensionState, set globals
│
├── Register commands (nim.run.file, nim.check, etc.) — no execution yet
│
├── processConfig(config) [nimProjects]
├── onDidChangeConfiguration → configUpdate [nimProjects]
├── onDidStartDebugSession → onStartDebugSession
│
├── setNimDir(state) [nimvscode.nim:353]
│   └── 🔴 cp.spawn("nimble", ["dump"]) ← external process
│
├── [if provider == "lsp"]
│   └── await startLanguageServer(true, state) [nimLsp.nim:341]
│       ├── getLspPath(state) [nimLsp.nim:116]
│       │   └── getBinPath("nimlangserver") [nimBinTools.nim:10]
│       │       └── 🔴 cp.execFileSync("readlink", [...]) ← on macOS/Linux
│       │
│       ├── getLatestReleasedLspVersion() [nimLsp.nim:72]
│       │   └── 🌐 fetch("https://api.github.com/repos/nim-lang/langserver/tags")
│       │
│       ├── handleLspVersion(nimlangserver, ...) [nimLsp.nim:176]
│       │   └── 🔴 cp.exec("nimlangserver --version") ← external process
│       │
│       ├── [if transportMode == "socket"]
│       │   └── startSocket() [nimLsp.nim:262]
│       │       └── 🔴 cp.exec("nimlangserver --socket") ← starts server
│       ├── [else stdio]
│       │   └── LanguageClient with ServerOptions{command: nimlangserver} ← starts server
│       │
│       ├── state.client.start() ← LSP handshake
│       ├── client.onNotification("extension/statusUpdate", ...)
│       ├── client.onNotification("window/showMessage", ...)
│       └── refreshNimbleTasks() → client.sendRequest("extension/tasks") ← LSP only ✅
│
├── [if provider == "nimsuggest"]
│   └── initNimSuggest() [nimSuggestExec.nim:89]
│       └── 🔴 cp.spawnSync("nimsuggest", ["--version"]) ← external process
│
├── diagnosticCollection = createDiagnosticCollection("nim")
├── vscode.languages.setLanguageConfiguration(...)
├── activateEvalConsole() [nimBuild]
│
├── initWorkspace(storagePath, ...) [nimIndexer]
│
├── fileWatcher = createFileSystemWatcher("**/*.nim")
│   ├── onDidCreate → addFileToImports [nimImports]
│   └── onDidDelete → removeFileFromImports [nimImports]
│
├── startBuildOnSaveWatcher(subscriptions) [nimvscode.nim:236]
│   └── [on save, if lintOnSave] → runCheck()
│       └── 🔴 check() [nimBuild] → cp.spawn("nim", ["check", ...])
│
├── [if lintOnSave and active editor]
│   └── runCheck() → 🔴 cp.spawn("nim", ["check", ...])
│
├── [if nimsuggestRestartTimeout > 0]
│   └── setInterval → closeAllNimSuggestProcesses() [every N minutes]
│
├── initImports() [nimImports]
│   ├── 🔴 cp.exec("nim dump <projectFile>") ← per project
│   ├── 🔴 cp.exec("nimble list -i") ← list installed packages
│   └── [per module] 🔴 cp.execSync("nimble --y dump <module>")
│
├── showNimbleSetupDialog() [nimvscode.nim:384]
│   └── [if .nimble exists and no nimble.paths]
│       └── execNimbleCmd(["setup"], ...) [nimBinTools.nim:101]
│           └── 🔴 cp.spawn("nimble", ["setup"]) ← NOTE: ignores `args`, always runs "setup"
│
├── newCodeLensProvider(...) + registerCodeLensProvider [nimcodelenses]
├── nimbleWatcher = createFileSystemWatcher("**/*.nimble")
└── initializeTests(ctx, state) [nimtest]
```

Key:

🔴 = external process spawn
🌐 = network request
✅ = goes through LSP (correct)
The bug worth noting: execNimbleCmd in nimBinTools.nim:103 ignores its args parameter entirely and always hardcodes ["setup"]. So even when called from installNimLangServer with ["install nimlangserver", "--accept", "-l"], it runs nimble setup instead. That's a latent bug on top of the spawn problem.

Summary of the problem: Even if the user has provider == "lsp", the extension still runs readlink, nimble dump, nim dump, nimble list -i, nimble dump (per module), and potentially nim check — all before the LSP is even done starting up.

