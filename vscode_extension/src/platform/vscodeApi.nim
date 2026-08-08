import std/jsffi
import js/[jsPromise, asyncjs, jsre, jsNode]

export jsffi, jsPromise, jsNode

## TODO: Move from JsObject to JsRoot for more explict errors

type
  VscodeThenable* = ref VscodeThenableObj
  VscodeThenableObj {.importc.} = object of JsRoot

  VscodeMarkdownString* = ref VscodeMarkdownStringObj
  VscodeMarkdownStringObj {.importc.} = object of JsObject
    value*: cstring

  VscodeUri* = ref VscodeUriObj
  VscodeUriObj {.importc.} = object of JsObject
    scheme*: cstring
    fsPath*: cstring
    path*: cstring

  VscodeUriChange* = ref object
    scheme*: cstring
    authority*: cstring
    path*: cstring
    query*: cstring
    fragment*: cstring

  VscodePosition* = ref VscodePositionObj
  VscodePositionObj {.importc.} = object of JsObject
    line*: cint
    character*: cint

  VscodeRange* = ref VscodeRangeObj
  VscodeRangeObj {.importc.} = object of JsObject
    start*: VscodePosition
    `end`*: VscodePosition
    ## `true` if `start` and `end` are equal.
    isEmpty*: bool

  VscodeCancellationToken* = ref VscodeCancellationTokenObj
  VscodeCancellationTokenObj {.importc.} = object of JsObject

  VscodeLocation* = ref VscodeLocationObj
  VscodeLocationObj {.importc.} = object of JsObject
    uri*: VscodeUri
    `range`*: VscodeRange

  VscodeSymbolKind* {.pure, nodecl.} = enum
    file = 0
    module = 1
    namespace = 2
    package = 3
    class = 4
    `method` = 5
    property = 6
    field = 7
    constructor = 8
    `enum` = 9
    `interface` = 10
    function = 11
    variable = 12
    constant = 13
    `string` = 14
    number = 15
    boolean = 16
    `array` = 17
    `object` = 18
    key = 19
    null = 20
    enumMember = 21
    struct = 22
    event = 23
    operator = 24
    typeParameter = 25

  VscodeSymbolInformation* = ref VscodeSymbolInformationObj
  VscodeSymbolInformationObj {.importc.} = object of JsRoot
    name*: cstring
    containerName*: cstring
    kind*: VscodeSymbolKind
    location*: VscodeLocation

  VscodeSymbolTag* {.pure, nodecl.} = enum
    deprecated = (1, "Deprecated")

  VscodeDocumentSymbol* = ref object
    children*: Array[VscodeDocumentSymbol]
    detail*: cstring
    kind*: VscodeSymbolKind
    name*: cstring
    `range`*: VscodeRange
    selectionRange*: VscodeRange
    tags: Array[VscodeSymbolTag]

  VscodeDiagnosticSeverity* {.nodecl, pure.} = enum
    ## Something not allowed by the rules of a language or other means.
    error = (0, "Error")
    ## Something suspicious but allowed.
    warning = (1, "Warning")
    ## Something to inform about but not a problem.
    information = (2, "Information")
    ## Something to hint to a better way of doing it, like proposing
    ## a refactoring.
    hint = (3, "Hint")

  ## Additional metadata about the type of a diagnostic.
  VscodeDiagnosticTag* {.nodecl, pure.} = enum
    ## Unused or unnecessary code.
    ##
    ## Diagnostics with this tag are rendered faded out. The amount of fading
    ## is controlled by the `"editorUnnecessaryCode.opacity"` theme color. For
    ## example, `"editorUnnecessaryCode.opacity": "#000000c0"` will render the
    ## code with 75% opacity. For high contrast themes, use the
    ## `"editorUnnecessaryCode.border"` theme color to underline unnecessary code
    ## instead of fading it out.
    unnecessary = (1, "Unnecessary")

  ## Represents a related message and source code location for a diagnostic. This should be
  ## used to point to code locations that cause or related to a diagnostics, e.g when duplicating
  ## a symbol in a scope.
  VscodeDiagnosticRelatedInformation* = ref VscodeDiagnosticRelatedInformationObj
  VscodeDiagnosticRelatedInformationObj {.importc.} = object of JsRoot
    ## The location of this related diagnostic information.
    location*: VscodeLocation
    ## The message of this related diagnostic information.
    message*: cstring

  ## Represents a diagnostic, such as a compiler error or warning. Diagnostic
  ## objects are only valid in the scope of a file.
  VscodeDiagnostic* = ref VscodeDiagnosticObj
  VscodeDiagnosticObj {.importc.} = object of JsRoot
    ## The range to which this diagnostic applies.
    `range`*: VscodeRange
    ## The human-readable message.
    message*: cstring
    ## The severity, default is [error](#DiagnosticSeverity.Error).
    severity*: VscodeDiagnosticSeverity
    ## A human-readable string describing the source of this
    ## diagnostic, e.g. 'typescript' or 'super lint'.
    source*: cstring
    ## A code or identifier for this diagnostics. Will not be surfaced
    ## to the user, but should be used for later processing, e.g. when
    ## providing [code actions](#CodeActionContext).
    code*: cstring
    ## An array of related diagnostic information, e.g. when symbol-names within
    ## a scope collide all definitions can be marked via this property.
    relatedInformation*: Array[VscodeDiagnosticRelatedInformation]
    ## Additional metadata about the diagnostic.
    tags*: Array[VscodeDiagnosticTag]

  VscodeDocumentFilter* = ref object
    language*: cstring
    scheme*: cstring

  ## Represents an item that can be selected from a list of items.
  VscodeQuickPickItem* = ref object
    ## A human readable string which is rendered prominent.
    label*: cstring
    ## A human readable string which is rendered less prominent.
    description*: cstring
    ## A human readable string which is rendered less prominent.
    detail*: cstring
    ## Optional flag indicating if this item is picked initially.
    ## (Only honored when the picker allows multiple selections.)
    ##
    ## @see [QuickPickOptions.canPickMany](#QuickPickOptions.canPickMany)
    picked*: bool

  VscodeTextLine* = ref VscodeTextLineObj
  VscodeTextLineObj {.importc.} = object of JsObject
    text*: cstring

  VscodeTextDocument* = ref VscodeTextDocumentObj
  VscodeTextDocumentObj {.importc.} = object of JsRoot
    fileName*: cstring
    uri*: VscodeUri
    isDirty*: bool
    languageId*: cstring
    isUntitled*: bool
    lineCount*: cint
  VscodeHoverLabel* = ref object
    # Not explictly named in vscode API, see type literal under MarkedString
    language*: cstring
    value*: cstring

  VscodeMarkedString* = ref VscodeMarkedStringObj
  VscodeMarkedStringObj {.importc.} = object of JsObject

  VscodeDecorationOptions* = ref object of VscodeDisposable
    range*: VscodeRange
    hoverMessage*: cstring
    command*: VscodeCommands

  VscodeHover* = ref VscodeHoverObj
  VscodeHoverObj {.importc.} = object of JsObject
    contents*: Array[VscodeMarkedString]
    `range`*: VscodeRange

  VscodeProgressLocation* {.pure, nodecl.} = enum
    ## Show progress for the source control viewlet, as overlay for the icon and as progress bar
    ## inside the viewlet (when visible). Neither supports cancellation nor discrete progress.
    sourceControl = (1, "SourceControl")
    ## Show progress in the status bar of the editor. Neither supports cancellation nor discrete progress.
    window = (10, "Window")
    ## Show progress as notification with an optional cancel button. Supports to show infinite and discrete progress.
    notification = (15, "Notification")

  VscodeProgress*[P] = proc(value: P): void

  VscodeProgressOptions* = ref VscodeProgressOptionsObj
  VscodeProgressOptionsObj {.importc.} = object of JsRoot
    location*: VscodeProgressLocation
    title*: cstring
    cancellable*: bool

  VscodeCompletionKind* {.pure, nodecl.} = enum
    text = 0
    `method` = 1
    function = 2
    constructor = 3
    field = 4
    variable = 5
    class = 6
    `interface` = 7
    module = 8
    property = 9
    unit = 10
    value = 11
    `enum` = 12
    keyword = 13
    snippet = 14
    color = 15
    file = 16
    reference = 17
    folder = 18
    enumMember = 19
    constant = 20
    struct = 21
    event = 22
    operator = 23
    typeParameter = 24

  VscodeFormattingOptions* = ref VscodeFormattingOptionsObj
  VscodeFormattingOptionsObj {.importc.} = object of JsObject

  VscodeParameterInformation* = ref VscodeParameterInformationObj
  VscodeParameterInformationObj {.importc.} = object of JsObject

  VscodeSignatureInformation* = ref VscodeSignatureInformationObj
  VscodeSignatureInformationObj {.importc.} = object of JsObject
    parameters*: Array[VscodeParameterInformation]

  VscodeSignatureHelp* = ref VscodeSignatureHelpObj
  VscodeSignatureHelpObj {.importc.} = object of JsObject
    signatures*: Array[VscodeSignatureInformation]
    activeSignature*: cint
    activeParameter*: cint

  VscodeConfigurationChangeEvent* = VscodeConfigurationChangeEventObj
  VscodeConfigurationChangeEventObj {.importc.} = object of JsRoot

  VscodeWorkspaceConfiguration* = ref VscodeWorkspaceConfigurationObj
  VscodeWorkspaceConfigurationObj {.importc.} = object of JsRoot
  VsCodeDebugConfiguration* = ref VsCodeDebugConfigurationObj
  VsCodeDebugConfigurationObj {.importc.} = object of JsRoot
    `type`*: cstring
    request*: cstring
    name*: cstring
    program*: cstring
    args*: Array[cstring]

  VscodeWorkspaceFolder* = ref VscodeWorkspaceFolderObj
  VscodeWorkspaceFolderObj {.importc.} = object of JsObject
    uri*: VscodeUri
    name*: cstring
    index*: cint

  VscodeCompletionItem* = ref VscodeCompletionItemObj
  VscodeCompletionItemObj {.importc.} = object of JsObject
    detail*: cstring
    sortText*: cstring
    insertText*: cstring
    documentation*: cstring
    documentationMD* {.importcpp: "documentation".}: VscodeMarkdownString

  VscodeTextEdit* = ref VscodeTextEditObj
  VscodeTextEditObj {.importc.} = object of JsObject

  VscodeReferenceContext* = ref VscodeReferenceContextObj
  VscodeReferenceContextObj {.importc.} = object of JsObject
    includeDeclaration*: bool

  VscodeDefinition* = ref VscodeDefinitionObj
  VscodeDefinitionObj {.importc.} = object of JsObject

  VscodeDefinitionLink* = ref VscodeDefinitionLinkObj
  VscodeDefinitionLinkObj {.importc.} = object of JsObject

  VscodeProviderResult* = VscodeDefinition or openArray[VscodeDefinitionLink]

  VscodeWorkspaceEdit* = ref VscodeWorkspaceEditObj
  VscodeWorkspaceEditObj {.importc.} = object of JsObject

  VscodeSelection* = ref VscodeSelectionObj
  VscodeSelectionObj {.importc.} = object of VscodeRange
    ## The position at which the selection starts.
    ## This position might be before or after [active](#Selection.active).
    anchor*: VscodePosition
    ## The position of the cursor.
    ## This position might be before or after [anchor](#Selection.anchor).
    active*: VscodePosition

  VscodeCompletionItemProvider* = ref VscodeCompletionItemProviderObj
  VscodeCompletionItemProviderObj {.importc.} = object of JsRoot

  VscodeDefinitionProvider* = ref VscodeDefinitionProviderObj
  VscodeDefinitionProviderObj {.importc.} = object of JsRoot

  VscodeReferenceProvider* = ref VscodeReferenceProviderObj
  VscodeReferenceProviderObj {.importc.} = object of JsRoot

  VscodeRenameProvider* = ref VscodeRenameProviderObj
  VscodeRenameProviderObj {.importc.} = object of JsRoot

  VscodeSignatureHelpProvider* = ref VscodeSignatureHelpProviderObj
  VscodeSignatureHelpProviderObj {.importc.} = object of JsRoot

  VscodeHoverProvider* = ref VscodeHoverProviderObj
  VscodeHoverProviderObj {.importc.} = object of JsRoot

  VscodeDocumentFormattingEditProvider* = ref VscodeDocumentFormattingEditProviderObj
  VscodeDocumentFormattingEditProviderObj {.importc.} = object of JsRoot

  VscodeDocumentSymbolProvider* = ref VscodeDocumentSymbolProviderObj
  VscodeDocumentSymbolProviderObj {.importc.} = object of JsRoot

  VscodeWorkspaceSymbolProvider* = ref VscodeWorkspaceSymbolProviderObj
  VscodeWorkspaceSymbolProviderObj {.importc.} = object of JsRoot

  VscodeTerminal* = ref VscodeTerminalObj
  VscodeTerminalObj {.importc.} = object of JsObject
    processId*: Future[cint]

  VscodeDisposable* = ref VscodeDisposableObj
  VscodeDisposableObj {.importc.} = object of JsObject

  VscodeDiagnosticCollection* = ref VscodeDiagnosticCollectionObj
  VscodeDiagnosticCollectionObj {.importc.} = object of VscodeDisposable

  VscodeFileSystem* = ref VscodeFileSystemObj
  VscodeFileSystemObj {.importc.} = object of JsRoot

  VscodeFileType* {.pure, nodecl.} = enum
    unknown = (0, "Unknown")
    file = (1, "File")
    directory = (2, "Directory")
    symbolicLink = (64, "SymbolicLink")
    symlinkFile = (65, "symlinkFile")
    symlinkDir = (66, "symlinkDir")

  VscodeReadDirResult* = ref VscodeReadDirResultObj
  VscodeReadDirResultObj {.importc.} = object of JsRoot

  VscodeFileSystemWatcher* = ref VscodeFileSystemWatcherObj
  VscodeFileSystemWatcherObj {.importc.} = object of VscodeDisposable

  ## A memento represents a storage utility. It can store and retrieve
  ## values.
  VscodeMemento* = ref object

  VscodeExtensionContext* = ref VscodeExtensionContextObj
  VscodeExtensionContextObj {.importc.} = object of JsRoot
    ## An array to which disposables can be added. When this
    ## extension is deactivated the disposables will be disposed.
    subscriptions*: Array[VscodeDisposable]
    ## A memento object that stores state in the context
    ## of the currently opened [workspace](#workspace.workspaceFolders).
    workspaceState*: VscodeMemento
    ## A memento object that stores state independent
    ## of the current opened [workspace](#workspace.workspaceFolders).
    globalState*: VscodeMemento
    ## The absolute file path of the directory containing the extension.
    extensionPath*: cstring
    ## An absolute file path of a workspace specific directory in which the extension
    ## can store private state. The directory might not exist on disk and creation is
    ## up to the extension. However, the parent directory is guaranteed to be existent.
    ##
    ## Use [`workspaceState`](#ExtensionContext.workspaceState) or
    ## [`globalState`](#ExtensionContext.globalState) to store key value data.
    storagePath*: cstring
    ## An absolute file path of a directory in which the extension can create log files.
    ## The directory might not exist on disk and creation is up to the extension. However,
    ## the parent directory is guaranteed to be existent.
    logPath*: cstring

  ## A tuple of two characters, like a pair of opening and closing brackets.
  VscodeCharacterPair* = array[2, cstring]

  ## Describes how comments for a language work.
  VscodeCommentRule* = ref object ## The line comment token, like `// this is a comment`
    lineComment*: cstring
    ## The block comment character pair, like `/* block comment *&#47;`
    blockComment*: Array[VscodeCharacterPair]

  VscodeIndentAction* {.nodecl, pure.} = enum
    none = (0, "None")
    indent = (1, "Indent")
    indentOutdent = (2, "IndentOutdent")
    outdent = (3, "Outdent")

  VscodeIndentationRule* = ref object
    ## If a line matches this pattern, then all the lines after it should
    ## be unindented once (until another rule matches).
    decreaseIndentPattern*: RegExp
    ## If a line matches this pattern, then all the lines after it should
    ## be indented once (until another rule matches).
    increaseIndentPattern*: RegExp
    ## If a line matches this pattern, then **only the next line** after it
    ## should be indented once.
    indentNextLinePattern*: RegExp
    ## If a line matches this pattern, then its indentation should not be
    ## changed and it should not be evaluated against the other rules.
    unIndentedLinePattern*: RegExp

  VscodeEnterAction* = ref object ## Describe what to do with the indentation.
    indentAction*: VscodeIndentAction
    ## Describes text to be appended after the new line and after the
    ## indentation.
    appendText*: cstring
    ## Describes the number of characters to remove from the new line's
    ## indentation.
    removeText*: cint

  VscodeOnEnterRule* = ref object
    ## This rule will only execute if the text before the cursor matches
    ## this regular expression.
    beforeText*: RegExp
    ## This rule will only execute if the text after the cursor matches
    ## this regular expression.
    afterText*: RegExp
    ## The action to execute.
    action*: VscodeEnterAction

  ## The language configuration interfaces defines the contract between
  ## extensions and various editor features, like automatic bracket
  ## insertion, automatic indentation etc.
  VscodeLanguageConfiguration* = ref object
    comments*: VscodeCommentRule
    ## This configuration implicitly affects pressing Enter around these brackets
    brackets*: Array[VscodeCharacterPair]
    ## The language's word definition.
    ## If the language supports Unicode identifiers (e.g. JavaScript), it is preferable
    ## to provide a word definition that uses exclusion of known separators.
    ## e.g.: A regex that matches anything except known separators (and dot is allowed to occur in a floating point number):
    ##    /(-?\d*\.\d\w*)|([^\`\~\!\@\#\%\^\&\*\(\)\-\=\+\[\{\]\}\\\|\;\:\'\"\,\.\<\>\/\?\s]+)/g
    wordPattern*: RegExp
    indentationRules*: VscodeIndentationRule
    onEnterRules*: Array[VscodeOnEnterRule]

  VscodeOutputChannel* = ref VscodeOutputChannelObj
  VscodeOutputChannelObj {.importc.} = object of JsRoot

  VscodeStatusBarItem* = ref VscodeStatusBarItemObj
  VscodeStatusBarItemObj {.importc.} = object of JsRoot
    text*: cstring
    command*: cstring
    color*: cstring
    tooltip*: cstring

  VscodeTextEditor* = ref VscodeTextEditorObj
  VscodeTextEditorObj {.importc.} = object of JsRoot
    document*: VscodeTextDocument
    selection*: VscodeSelection

  VscodeWorkspace* = ref VscodeWorkspaceObj
  VscodeWorkspaceObj {.importc.} = object of JsRoot
    rootPath*: cstring
    workspaceFolders*: Array[VscodeWorkspaceFolder]
    fs*: VscodeFileSystem

  VscodeLanguages* = ref VscodeLanguagesObj
  VscodeLanguagesObj {.importc.} = object of JsRoot

  VscodeWindow* = ref VscodeWindowObj
  VscodeWindowObj {.importc.} = object of JsRoot
    activeTextEditor*: VscodeTextEditor
    visibleTextEditors*: Array[VscodeTextEditor]

  VscodeMessageItem* = ref VscodeMessageItemObj
  VscodeMessageItemObj {.importc.} = object of JsRoot
    isCloseAffordance*: bool
    title*: cstring

  VscodeMessageOptions* = ref VscodeMessageOptionsObj
  VscodeMessageOptionsObj {.importc.} = object of JsRoot
    detail*: cstring
    modal*: bool

  VscodeCommands* = ref VscodeCommandsObj
  VscodeCommandsObj {.importc.} = object of JsObject
    title*: cstring
    command*: cstring

  VscodeDebug* = ref VscodeDebugObj
  VscodeDebugObj {.importc.} = object of JsObject

  VscodeDebugSession* = ref VScodeDebugSessionObj
  VscodeDebugSessionObj {.importc.} = object of JsObject

  VSCodeDebugExpression* = ref VSCodeDebugExpressionObj
  VSCodeDebugExpressionObj {.importc.} = object of JsObject
    expression*: cstring
    context*: cstring

  VscodeStatusBarAlignment* {.nodecl, pure.} = enum
    left = 1
    right = 2

  VscodeEnv* = ref object ## The application name of the editor, like 'VS Code'.
    appName*: cstring
    ## The application root folder from which the editor is running.
    appRoot*: cstring
    ## Represents the preferred user-language, like `de-CH`, `fr`, or `en-US`.
    language*: cstring
    ## A unique identifier for the computer.
    machineId*: cstring
    ## A unique identifier for the current session.
    sessionId*: cstring

  VscodeTests* = ref object of JsObject

  Vscode* = ref VscodeObj
  VscodeObj {.importc.} = object of JsRoot
    env*: VscodeEnv
    window*: VscodeWindow
    commands*: VscodeCommands
    workspace*: VscodeWorkspace
    languages*: VscodeLanguages
    debug*: VscodeDebug
    tests*: VscodeTests
    lm*: VscodeLm

  VscodeTextEditorOptions* = ref object of JsObject
    viewColumn*: VscodeViewColumn
    preserveFocus*: bool
    preview*: bool
    selection*: VscodeRange
    isPreview*: bool

  VscodeViewColumn* {.size: sizeof(int32).} = enum
    beside = -2
    active = -1
    one = 1
    two = 2

  VscodeWebviewPanelOptions* = ref object of JsObject
    enableScripts*: bool
    enableForms*: bool
    enableCommandUris*: bool
    localResourceRoots*: seq[string]
    portMapping*: seq[JsObject]
    retainContextWhenHidden*: bool
      # You can define a more specific type for port mapping if needed

  TreeItem* = ref object of JsObject
    label*: cstring
    description*: cstring
    tooltip*: cstring
    collapsibleState*: int
    contextValue*: cstring
    command*: JsObject
    iconPath*: JsObject

  EventEmitter* = ref object of JsObject
    fire*: proc(data: JsObject)

  McpStdioServerDefinition* = ref object of JsObject
    label*: cstring
    command*: cstring
    args*: seq[cstring]

  McpServerDefinitionProvider* = ref object of JsObject
   provideMcpServerDefinitions*: proc(): seq[McpStdioServerDefinition]

  VscodeLm* = ref object of JsObject

  # TreeDataProvider* = ref object of JsObject
  #   onDidChangeTreeData*: EventEmitter
  VscodeTextEditorSelectionChangeEvent* = ref object of JsObject
    textEditor*: VscodeTextEditor
  
  VscodeCodeLensProvider* = ref VscodeCodeLensProviderObj
  VscodeCodeLensProviderObj {.importc.} = object of JsObject

  VscodeCodeLens* = ref VscodeCodeLensObj
  VscodeCodeLensObj {.importc.} = object of JsObject
    range*: VscodeRange
    command*: VscodeCommands
  VscodeThemableDecorationAttachmentRenderOptions* = ref object of JsObject
    contentText*: cstring
    color*: cstring
    backgroundColor*: cstring
    margin*: cstring
    border*: cstring
    fontFamily*: cstring
    padding*: cstring

  VscodeDecorationRenderOptions* = ref object of JsObject
    after*: VscodeThemableDecorationAttachmentRenderOptions
    isWholeLine*: bool
    backgroundColor*: cstring
    before*: VscodeThemableDecorationAttachmentRenderOptions
    gutterIconPath*: cstring
    gutterIconSize*: cstring
    border*: cstring
    textDecoration*: cstring
    color*: cstring
  VscodeTextEditorDecorationType* = ref VscodeTextEditorDecorationTypeObj
  VscodeTextEditorDecorationTypeObj {.importc.} = object of JsObject
  
  VscodeTextDocumentShowOptions* = ref object
    viewColumn*: VscodeViewColumn
    preserveFocus*: bool
    preview*: bool
    selection*: VscodeRange
    isPreview*: bool
 
proc then*(
  self: VscodeThenable,
  onfulfilled: proc(value: JsRoot): JsRoot,
  onrejected: proc(reason: JsRoot): JsRoot,
): VscodeThenable {.importcpp, discardable.}

proc cstringToMarkedString(s: cstring): VscodeMarkedString {.importcpp: "#".}
converter toVscodeMarkedString*(s: cstring): VscodeMarkedString =
  s.cstringToMarkedString()

proc hoverLabelToMarkedString(
  s: VscodeHoverLabel
): VscodeMarkedString {.importcpp: "#".}

converter toVscodeMarkedString*(s: VscodeHoverLabel): VscodeMarkedString =
  s.hoverLabelToMarkedString()

proc markdownStringToMarkedString(
  s: VscodeMarkdownString
): VscodeMarkedString {.importcpp: "#".}

converter toVscodeMarkedString*(s: VscodeMarkdownString): VscodeMarkedString =
  s.markdownStringToMarkedString()



# static function
proc newWorkspaceEdit*(
  vscode: Vscode
): VscodeWorkspaceEdit {.importcpp: "(new #.WorkspaceEdit(@))".}

proc newPosition*(
  vscode: Vscode, start: cint, `end`: cint
): VscodePosition {.importcpp: "(new #.Position(@))".}

proc newRange*(
  vscode: Vscode, start: VscodePosition, `end`: VscodePosition
): VscodeRange {.importcpp: "(new #.Range(@))".}

proc newRange*(
  vscode: Vscode, startA, endA, startB, endB: cint
): VscodeRange {.importcpp: "(new #.Range(@))".}

proc newDiagnostic*(
  vscode: Vscode, r: VscodeRange, msg: cstring, sev: VscodeDiagnosticSeverity
): VscodeDiagnostic {.importcpp: "(new #.Diagnostic(@))".}

proc newDiagnosticRelatedInformation*(
  vscode: Vscode, location: VscodeLocation, message: cstring
): VscodeDiagnosticRelatedInformation {.
  importcpp: "new #.DiagnosticRelatedInformation(@)"
.}

proc newLocation*(
  vscode: Vscode, uri: VscodeUri, pos: VscodePosition | VscodeRange
): VscodeLocation {.importcpp: "(new #.Location(@))".}

proc newCompletionItem*(
  vscode: Vscode, name: cstring, kind: VscodeCompletionKind
): VscodeCompletionItem {.importcpp: "(new #.CompletionItem(@))".}

proc newMarkdownString*(
  vscode: Vscode, text: cstring
): VscodeMarkdownString {.importcpp: "(new #.MarkdownString(@))".}

proc newSignatureHelp*(
  vscode: Vscode
): VscodeSignatureHelp {.importcpp: "(new #.SignatureHelp(@))".}

proc newSignatureInformation*(
  vscode: Vscode, kind: cstring, docString: cstring
): VscodeSignatureInformation {.importcpp: "(new #.SignatureInformation(@))".}

proc newParameterInformation*(
  vscode: Vscode, name: cstring
): VscodeParameterInformation {.importcpp: "(new #.ParameterInformation(@))".}

proc newDocumentSymbol*(
  vscode: Vscode,
  name: cstring,
  detail: cstring,
  kind: VscodeSymbolKind,
  rng: VscodeRange,
  selectionRange: VscodeRange,
): VscodeDocumentSymbol {.importcpp: "(new #.DocumentSymbol(@))".}

proc newSymbolInformation*(
  vscode: Vscode,
  name: cstring,
  kind: VscodeSymbolKind,
  container: cstring,
  loc: VscodeLocation,
): VscodeSymbolInformation {.importcpp: "(new #.SymbolInformation(@))".}

proc newSymbolInformation*(
  vscode: Vscode,
  name: cstring,
  kind: VscodeSymbolKind,
  rng: VscodeRange,
  file: VscodeUri,
  container: cstring,
): VscodeSymbolInformation {.importcpp: "(new #.SymbolInformation(@))", deprecated.}

proc newVscodeHover*(
  vscode: Vscode, contents: VscodeMarkedString
): VscodeHover {.importcpp: "(new #.Hover(@))".}

proc newVscodeHover*(
  vscode: Vscode, contents: Array[VscodeMarkedString]
): VscodeHover {.importcpp: "(new #.Hover(@))".}

proc newVscodeHover*(
  vscode: Vscode, contents: VscodeMarkedString, `range`: VscodeRange
): VscodeHover {.importcpp: "(new #.Hover(@))".}

proc newVscodeHover*(
  vscode: Vscode, contents: Array[VscodeMarkedString], `range`: VscodeRange
): VscodeHover {.importcpp: "(new #.Hover(@))".}

proc newCodeLens*(
  vscode: Vscode, range: VscodeRange, command: VscodeCommands
): VscodeCodeLens {.importcpp: "(new #.CodeLens(@))".}

proc uriFile*(vscode: Vscode, file: cstring): VscodeUri {.importcpp: "(#.Uri.file(@))".}
proc newWorkspaceFolderLike*(
  uri: VscodeUri, name: cstring, index: cint
): VscodeWorkspaceFolder {.importcpp: "({uri:#, name:#, index:#})".}

#https://code.visualstudio.com/api/references/theme-color#notification-colors
proc themeColor*(
  vscode: Vscode, color: cstring
): JsObject {.importjs: "new #.ThemeColor(#)".}

# https://code.visualstudio.com/api/references/icons-in-labels#icon-listing
proc themeIcon*(
  vscode: Vscode, name: cstring, color: JsObject = nil
): JsObject {.importjs: "new #.ThemeIcon(@)".}

# Command
proc registerCommand*(
  cmds: VscodeCommands, name: cstring, fn: proc(): void
): void {.importcpp.}

proc registerCommand*(
  cmds: VscodeCommands, name: cstring, fn: proc(): Future[void]
): void {.importcpp.}

# Uri
proc with*(uri: VscodeUri, change: VscodeUriChange): VscodeUri {.importcpp.}

# Output
proc showInformationMessage*(win: VscodeWindow, msg: cstring) {.importcpp.}
proc showInformationMessage*(
  win: VscodeWindow, message: cstring, options: VscodeMessageOptions
): VscodeThenable {.importcpp, varargs, discardable.} ## shows an informational message

proc showErrorMessage*(win: VscodeWindow, message: cstring) {.importcpp.}

# Workspace
proc saveAll*(
  ws: VscodeWorkspace, includeUntitledFile: bool
): Future[bool] {.importcpp.}

proc getConfiguration*(
  ws: VscodeWorkspace, name: cstring
): VscodeWorkspaceConfiguration {.importcpp.}

proc getConfiguration*(
  ws: VscodeWorkspace, name: cstring, scope: VscodeUri
): VscodeWorkspaceConfiguration {.importcpp.}

proc getConfiguration*(
  ws: VscodeWorkspace, name: cstring, scope: VscodeWorkspaceFolder
): VscodeWorkspaceConfiguration {.importcpp.}

proc onDidChangeConfiguration*(
  ws: VscodeWorkspace, cb: proc(): void
): VscodeDisposable {.importcpp.}

proc onDidChangeConfiguration*(
  ws: VscodeWorkspace, cb: proc(e: VscodeConfigurationChangeEvent): void
): VscodeDisposable {.importcpp.}

proc onDidSaveTextDocument*[T](
  ws: VscodeWorkspace,
  cb: proc(d: VscodeTextDocument): void,
  thisArg: T,
  disposables: Array[VscodeDisposable],
): VscodeDisposable {.importcpp, discardable.}

proc findFiles*(
  ws: VscodeWorkspace, includeGlob: cstring
): Future[Array[VscodeUri]] {.importcpp.}

proc findFiles*(
  ws: VscodeWorkspace, includeGlob: cstring, excludeGlob: cstring
): Future[Array[VscodeUri]] {.importcpp.}

proc getWorkspaceFolder*(
  ws: VscodeWorkspace, folder: VscodeUri
): VscodeWorkspaceFolder {.importcpp.}

proc asRelativePath*(
  ws: VscodeWorkspace, filename: cstring, includeWorkspaceFolder: bool
): cstring {.importcpp.}

proc createFileSystemWatcher*(
  ws: VscodeWorkspace, glob: cstring
): VscodeFileSystemWatcher {.importcpp.}

proc getDocument*(
  ws: VscodeWorkspace, uri: cstring
): VscodeTextDocument {.importcpp.}

proc applyEdit*(
  ws: VscodeWorkspace, e: VscodeWorkspaceEdit
): Future[bool] {.importcpp, discardable.}

# FileSystem
proc readDirectory*(
  fs: VscodeFileSystem, uri: VscodeUri
): Future[Array[VscodeReadDirResult]] {.importcpp.}

proc name*(r: VscodeReadDirResult): cstring {.importcpp: "#[0]".}
proc `name=`*(r: VscodeReadDirResult, n: cstring) {.importcpp: "(#[0]=#)".}
proc fileType*(r: VscodeReadDirResult): VscodeFileType {.importcpp: "#[1]".}
proc `fileType=`*(r: VscodeReadDirResult, f: VscodeFileType) {.importcpp: "(#[1]=#)".}

# WorkspaceConfiguration
proc has*(c: VscodeWorkspaceConfiguration, section: cstring): bool {.importcpp.}
proc get*(c: VscodeWorkspaceConfiguration, section: cstring): JsObject {.importcpp.}
proc getBool*(
  c: VscodeWorkspaceConfiguration, section: cstring
): bool {.importcpp: "#.get(@)".}

proc getBool*(
  c: VscodeWorkspaceConfiguration, section: cstring, default: bool
): bool {.importcpp: "#.get(@)".}

proc getInt*(
  c: VscodeWorkspaceConfiguration, section: cstring
): cint {.importcpp: "#.get(@)".}

proc getStr*(
  c: VscodeWorkspaceConfiguration, section: cstring
): cstring {.importcpp: "#.get(@)".}

proc getStrArray*(
  c: VscodeWorkspaceConfiguration, section: cstring
): Array[cstring] {.importcpp: "#.get(@)".}

proc getStrBoolMap*(
  c: VscodeWorkspaceConfiguration,
  section: cstring,
  default: JsAssoc[cstring, bool] = newJsAssoc[cstring, bool](),
): JsAssoc[cstring, bool] {.importcpp: "#.get(@)".}

# FileSystemWatcher
proc dispose*(w: VscodeFileSystemWatcher): void {.importcpp.}
proc onDidCreate*(
  w: VscodeFileSystemWatcher, listener: proc(uri: VscodeUri): void
): VscodeDisposable {.importcpp, discardable.}

proc onDidDelete*(
  w: VscodeFileSystemWatcher, listener: proc(uri: VscodeUri): void
): VscodeDisposable {.importcpp, discardable.}

proc onDidChange*(
  w: VscodeFileSystemWatcher, listener: proc(uri: VscodeUri): void
): VscodeDisposable {.importcpp, discardable.}

#Debug
proc startDebugging*(
  debug: VScodeDebug,
  folder: VscodeWorkspaceFolder,
  config: cstring | VsCodeDebugConfiguration,
): Future[bool] {.importcpp.}

proc onDidStartDebugSession*(
  debug: VscodeDebug, listener: proc(session: VscodeDebugSession): void
): VscodeDisposable {.importcpp, discardable.}

proc customRequest*(
  session: VscodeDebugSession, command: cstring, arg: VscodeDebugExpression
): Future[JsObject] {.importcpp.}

# Languages
proc match*(
  langs: VscodeLanguages, selector: VscodeDocumentFilter, doc: VscodeTextDocument
): cint {.importcpp.}

proc createDiagnosticCollection*(
  langs: VscodeLanguages, selector: cstring
): VscodeDiagnosticCollection {.importcpp.}

proc setLanguageConfiguration*(
  langs: VscodeLanguages, lang: cstring, config: VscodeLanguageConfiguration
): VscodeDisposable {.importcpp, discardable.}

proc registerCompletionItemProvider*(
  langs: VscodeLanguages,
  selector: VscodeDocumentFilter,
  provider: VscodeCompletionItemProvider,
  triggerCharacters: cstring,
): VscodeDisposable {.importcpp, varargs.}

proc registerDefinitionProvider*(
  langs: VscodeLanguages,
  selector: VscodeDocumentFilter,
  provider: VscodeDefinitionProvider,
): VscodeDisposable {.importcpp.}

proc registerReferenceProvider*(
  langs: VscodeLanguages,
  selector: VscodeDocumentFilter,
  provider: VscodeReferenceProvider,
): VscodeDisposable {.importcpp.}

proc registerRenameProvider*(
  langs: VscodeLanguages, selector: VscodeDocumentFilter, provider: VscodeRenameProvider
): VscodeDisposable {.importcpp.}

proc registerDocumentSymbolProvider*(
  langs: VscodeLanguages,
  selector: VscodeDocumentFilter,
  provider: VscodeDocumentSymbolProvider,
): VscodeDisposable {.importcpp.}

proc registerSignatureHelpProvider*(
  langs: VscodeLanguages,
  selector: VscodeDocumentFilter,
  provider: VscodeSignatureHelpProvider,
  triggerCharacters: cstring,
): VscodeDisposable {.importcpp, varargs.}

proc registerHoverProvider*(
  langs: VscodeLanguages, selector: VscodeDocumentFilter, provider: VscodeHoverProvider
): VscodeDisposable {.importcpp.}

proc registerDocumentFormattingEditProvider*(
  langs: VscodeLanguages,
  selector: VscodeDocumentFilter,
  provider: VscodeDocumentFormattingEditProvider,
): VscodeDisposable {.importcpp.}

proc registerWorkspaceSymbolProvider*(
  langs: VscodeLanguages, provider: VscodeWorkspaceSymbolProvider
): VscodeDisposable {.importcpp.}

proc registerCodeLensProvider*(
  langs: VscodeLanguages,
  selector: VscodeDocumentFilter,
  provider: VscodeCodeLensProvider,
): VscodeDisposable {.importcpp.}

# Window
proc createTerminal*(window: VscodeWindow, name: cstring): VscodeTerminal {.importcpp.}
proc withProgress*[R](
  window: VscodeWindow, options: VscodeProgressOptions, task: proc(): Future[R]
): Future[R] {.importcpp.}

proc withProgress*[R, P](
  window: VscodeWindow,
  options: VscodeProgressOptions,
  task: proc(progress: var VscodeProgress[P]): Future[R],
): Future[R] {.importcpp.}

proc createStatusBarItem*(
  window: VscodeWindow, align: VscodeStatusBarAlignment, val: cdouble
): VscodeStatusBarItem {.importcpp.}

proc createOutputChannel*(
  window: VscodeWindow, s: cstring
): VscodeOutputChannel {.importcpp.}

proc onDidCloseTerminal*(
  window: VscodeWindow, listener: proc(t: VscodeTerminal): void
): VscodeDisposable {.importcpp, discardable.}

proc onDidOpenTerminal*(
  window: VscodeWindow, listener: proc(t: VscodeTerminal): void
): VscodeDisposable {.importcpp, discardable.}

proc onDidChangeActiveTextEditor*[T](
  window: VscodeWindow,
  listener: proc(): void,
  thisArg: T,
  disposables: Array[VscodeDisposable],
): VscodeDisposable {.importcpp, discardable.}

proc onDidChangeTextEditorSelection*(
  window: VscodeWindow, listener: proc(e: VscodeTextEditorSelectionChangeEvent): void
): VscodeDisposable {.importcpp, discardable.}


proc showQuickPick*(
  window: VscodeWindow, items: Array[VscodeQuickPickItem]
): Future[VscodeQuickPickItem] {.importcpp.}

proc registerTreeDataProvider*(
  window: VscodeWindow, viewId: cstring, treeDataProvider: JsObject
): VscodeDisposable {.importcpp.}

const
  TreeItemCollapsibleState_None* = 0
  TreeItemCollapsibleState_Collapsed* = 1
  TreeItemCollapsibleState_Expanded* = 2

proc createWebviewPanel*(
  window: VscodeWindow,
  viewType: cstring,
  title: cstring,
  showOptions: VscodeViewColumn,
  options: VscodeWebviewPanelOptions,
): JsObject {.importjs: "#.createWebviewPanel(@)".}

proc createWebviewPanel*(
  window: VscodeWindow,
  viewType: cstring,
  title: cstring,
  showOptions: JsObject,
  options: VscodeWebviewPanelOptions,
): JsObject {.importjs: "#.createWebviewPanel(@)".}

proc newEventEmitter*(
  vscode: Vscode
): EventEmitter {.importcpp: "new #.EventEmitter()".}

proc newTreeItem*(
  vscode: Vscode, label: cstring, collapsibleState: int = 0
): TreeItem {.importcpp: "new #.TreeItem(@)".}

# Terminal
proc sendText*(term: VscodeTerminal, name: cstring): void {.importcpp.}
proc sendText*(
  term: VscodeTerminal, name: cstring, addNewLine: bool
): void {.importcpp.}

proc show*(term: VscodeTerminal, preserveFocus: bool): void {.importcpp.}

# OutputChannel
proc appendLine*(c: VscodeOutputChannel, line: cstring): void {.importcpp.}

# StatusBarItem
proc show*(item: VscodeStatusBarItem): void {.importcpp.}
proc hide*(item: VscodeStatusBarItem): void {.importcpp.}
proc dispose*(item: VscodeStatusBarItem): void {.importcpp.}

# TextDocument
proc save*(doc: VscodeTextDocument): Future[bool] {.importcpp.}
proc lineAt*(doc: VscodeTextDocument, line: cint): VscodeTextLine {.importcpp.}
proc lineAt*(
  doc: VscodeTextDocument, position: VscodePosition
): VscodeTextLine {.importcpp.}

proc getText*(doc: VscodeTextDocument): cstring {.importcpp.}
proc getText*(doc: VscodeTextDocument, `range`: VscodeRange): cstring {.importcpp.}
proc getWordRangeAtPosition*(
  doc: VscodeTextDocument, position: VscodePosition
): VscodeRange {.importcpp.}

proc getWordRangeAtPosition*(
  doc: VscodeTextDocument, position: VscodePosition, regex: RegExp
): VscodeRange {.importcpp.}

proc validateRange*(
  doc: VscodeTextDocument, `range`: VscodeRange
): VscodeRange {.importcpp.}

# Range
proc with*(
  `range`: VscodeRange, start: VscodePosition = nil, `end`: VscodePosition = nil
): VscodeRange {.importcpp: "#.with({start:#, end:#})".}

# TextEdit

## static function, but the import in js is "dynamic" in the variable it's assigned to
proc textEditReplace*(
  vscode: Vscode, `range`: VscodeRange, content: cstring
): VscodeTextEdit {.importcpp: "#.TextEdit.replace(@)".}

# DiagnosticCollection
# proc set*(c:VscodeDiagnosticCollection, entries:seq[])

# Events

proc affectsConfiguration*(
  event: VscodeConfigurationChangeEvent, section: cstring
): bool {.importcpp.}

# Memento
proc get*[T](m: VscodeMemento, k: cstring): T {.importcpp.} ## a value or nil
proc get*[T](m: VscodeMemento, k: cstring, defaultVal: T): T {.importcpp.}
  ## stored value or the default value

proc update*[T](m: VscodeMemento, k: cstring, v: T): Future[void] {.importcpp.}
  ## value must not contain cyclic references

var vscode*: Vscode = require("vscode").to(Vscode)

## References / Helpful Links
##
## Union types for function input params arguments: https://forum.nim-lang.org/t/1628
## Nim ES2015 class macros: https://github.com/kristianmandrup/nim_es2015_classes/blob/master/src/es_class.nim

proc newCodeLensProvider*(
  provideCodeLenses: proc(document: VscodeTextDocument, token: VscodeCancellationToken): seq[VscodeCodeLens]
): VscodeCodeLensProvider {.importcpp: """({
  provideCodeLenses: #
})""".}

proc createTextEditorDecorationType*(
  self: VscodeWindow, 
  options: VscodeDecorationRenderOptions
): VscodeTextEditorDecorationType {.importcpp: "#.createTextEditorDecorationType(#)".}

proc setDecorations*(
  editor: VscodeTextEditor,
  decorationType: VscodeTextEditorDecorationType,
  rangeOrOptions: openArray[VscodeDecorationOptions]
) {.importcpp: "#.setDecorations(#, #)".}

proc showTextDocument*(
  window: VscodeWindow,
  document: VscodeTextDocument,
  options: VscodeTextDocumentShowOptions = nil
): Future[VscodeTextEditor] {.importcpp.}

proc createTextDocument*(
  workspace: VscodeWorkspace,
  content: cstring
): Future[VscodeTextDocument] {.importcpp: "#.openTextDocument({content: #})".}

proc createTextDocument*(
  workspace: VscodeWorkspace,
  options: VscodeTextDocumentShowOptions
): Future[VscodeTextDocument] {.importcpp: "#.openTextDocument(#)".}

proc openTextDocument*(
  workspace: VscodeWorkspace,
  uri: VscodeUri
): Future[VscodeTextDocument] {.importcpp: "#.openTextDocument(#)".}

proc asAbsolutePath*(ctx: VscodeExtensionContext, relativePath: cstring): cstring {.importjs: "#.asAbsolutePath(#)".}

# Add these type definitions

type
  VscodeTestItem* = ref object of JsObject
    id*: cstring
    label*: cstring
    uri*: VscodeUri
    range*: VscodeRange
    children*: VscodeTestItemCollection
  
  VscodeTestRunRequest* = ref object of JsObject
    `include`*: VscodeTestItemCollection
    exclude*: seq[VscodeTestItem]
    profile*: VscodeTestRunProfile
    continuous*: bool
    debug*: bool

  VscodeTestItemCollection* = ref object of JsObject
  VscodeTestController* = ref object of VscodeDisposable
    items*: VscodeTestItemCollection
    error*: VscodeTestMessage
    createRunProfile*: proc(
      label: cstring,
      kind: VscodeTestRunProfileKind,
      runHandler: proc(request: VscodeTestRunRequest, token: VscodeCancellationToken),
      isDefault: bool = false
    ): VscodeTestRunProfile
    refreshHandler*: proc()
    errorHandler*: proc()

  VscodeTestRunProfile* = ref object of JsObject
    kind*: VscodeTestRunProfileKind
    label*: cstring

  VscodeTestMessage* = ref object of JsObject
    message*: cstring
    expectedOutput*: cstring
    actualOutput*: cstring
    location*: VscodeLocation

  VscodeTestRun* = ref object of JsObject

  VscodeTestRunProfileKind* {.pure.} = enum
    Run = 1
    Debug = 2
    Coverage = 3

proc createTestRun*(controller: VscodeTestController, request: VscodeTestRunRequest): VscodeTestRun {.importcpp: "#.createTestRun(#)".}
proc createTestItem*(
  controller: VscodeTestController, 
  id: cstring, 
  label: cstring, 
  uri: VscodeUri = nil
): VscodeTestItem {.importcpp.}

proc createRunProfile*(
  controller: VscodeTestController,
  label: cstring,
  kind: VscodeTestRunProfileKind,
  runHandler: proc(request: JsObject, token: VscodeCancellationToken),
  isDefault: bool = false
): VscodeTestRunProfile {.importcpp: "#.createTestRunProfile(@)".}

# Add method to get items collection
proc getItems*(controller: VscodeTestController): VscodeTestItemCollection {.importcpp: "#.items".}
proc getItem*(controller: VscodeTestController, id: cstring): VscodeTestItem {.importcpp: "#.getItem(#)".}

# Add methods for TestItemCollection
proc add*(collection: VscodeTestItemCollection, item: VscodeTestItem) {.importcpp: "#.add(#)".}
proc delete*(collection: VscodeTestItemCollection, item: VscodeTestItem) {.importcpp: "#.delete(#)".}
proc forEach*(collection: VscodeTestItemCollection, callback: proc(item: VscodeTestItem)) {.importcpp: "#.forEach(#)".}
proc size*(collection: VscodeTestItemCollection): cint {.importcpp: "#.size".}
proc clear*(collection: VscodeTestItemCollection) {.importcpp: "#.clear".}

# Test item methods
proc getChildren*(item: VscodeTestItem): Array[VscodeTestItem] {.importcpp: "#.children".}
proc getId*(item: VscodeTestItem): cstring {.importcpp: "#.id".}
proc getLabel*(item: VscodeTestItem): cstring {.importcpp: "#.label".}
proc getUri*(item: VscodeTestItem): VscodeUri {.importcpp: "#.uri".}
proc getRange*(item: VscodeTestItem): VscodeRange {.importcpp: "#.range".}

# Test controller methods
proc enqueued*(run: VscodeTestRun, test: VscodeTestItem) {.importcpp: "#.enqueued(@)".}
proc passed*(run: VscodeTestRun, test: VscodeTestItem, message: VscodeTestMessage = nil, duration: float = 0) {.importcpp: "#.passed(@)".}
proc failed*(run: VscodeTestRun, test: VscodeTestItem, message: VscodeTestMessage = nil, duration: float = 0) {.importcpp: "#.failed(@)".}
proc skipped*(run: VscodeTestRun, test: VscodeTestItem) {.importcpp: "#.skipped(@)".}
proc started*(run: VscodeTestRun, test: VscodeTestItem) {.importcpp: "#.started(@)".}
proc ended*(run: VscodeTestRun, test: VscodeTestItem = nil) {.importcpp: "#.end(@)".}

# Add the creation function
proc createTestController*(
  tests: VscodeTests,
  id: cstring,
  label: cstring
): VscodeTestController {.importcpp: "#.createTestController(@)".}

proc isCancellationRequested*(token: VscodeCancellationToken): bool {.importcpp: "#.isCancellationRequested".}

proc newMcpStdioServerDefinition*(
  vscode: Vscode,
  label: cstring,
  command: cstring,
  args: seq[cstring]
): McpStdioServerDefinition {.importcpp: "new #.McpStdioServerDefinition(@)".}

proc registerMcpServerDefinitionProvider*(
  lm: VscodeLm,
  id: cstring,
  provider: McpServerDefinitionProvider
): VscodeDisposable {.importcpp: "#.registerMcpServerDefinitionProvider(#, #)".}
