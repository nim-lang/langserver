import platform/vscodeApi
import std/[strformat, jsconsole, tables, options, sequtils, strutils]
import platform/js/jsNodeFs
import ../state/state_types
import ../language_server/language_server
import ../tools/nimUtils

var testController: VscodeTestController
var runProfile: VscodeTestRunProfile = nil

# Maps every test item ID → its entry point path.
# Also used for suite and project items.
var itemEntryPoint: Table[cstring, cstring]

# Maps test item IDs → the suite name they belong to.
# Needed when running a single test so we can pass suiteName to the LSP.
var itemSuiteName: Table[cstring, cstring]

# --- helpers -----------------------------------------------------------------

proc getProjectLabel(entryPoint: cstring): cstring =
  ## Short display name for a project: first path component.
  ## "langserver/tests/all.nim" -> "langserver"
  let parts = ($entryPoint).split("/")
  if parts.len > 1: parts[0].cstring else: entryPoint

proc getEntryPoints(state: ExtensionState): seq[cstring] =
  ## Returns all configured test entry points.
  ## Reads nimTortoise.test.entryPoints (array); falls back to the legacy
  ## nimTortoise.test.entryPoint (single string) and then dumpTestEntryPoint.
  let arr = state.config.getStrArray("test.entryPoints")
  for ep in arr:
    if $ep != "":
      result.add(ep)
  if result.len == 0:
    let single = state.config.getStr("test.entryPoint")
    if $single != "":
      result.add(single)
    elif $state.dumpTestEntryPoint != "":
      result.add(state.dumpTestEntryPoint)

# --- ID scheme ---------------------------------------------------------------
# Project item : "p:<entryPoint>"
# Suite item   : "s:<entryPoint>|<suiteName>"
# Test item    : "t:<entryPoint>|<suiteName>|<testName>"
#
# The prefix lets runSingleTest decide what level was clicked without needing
# parent-pointer traversal (which the VS Code TestItem API doesn't expose).

proc projectId(ep: cstring): cstring = ("p:" & $ep).cstring
proc suiteId(ep, suiteName: cstring): cstring = ("s:" & $ep & "|" & $suiteName).cstring
proc testId(ep, suiteName, testName: cstring): cstring =
  ("t:" & $ep & "|" & $suiteName & "|" & $testName).cstring

# --- result rendering --------------------------------------------------------

proc renderTestResult(
    test: VscodeTestItem, result: RunTestResult,
    run: VscodeTestRun, fullOutput: cstring = "") =
  let duration = result.time * 1000
  if result.failure.isNull:
    run.passed(test, duration = duration)
    run.appendOutput(&"[{test.label}] Test passed in {duration:.4f}ms\n")
  else:
    run.failed(test, VscodeTestMessage(message: result.failure), duration = duration)
    run.appendOutput(&"[{test.label}] Test failed with error:\n")
    run.appendOutput(result.failure)
    run.appendOutput(&"[{test.label}] Test failed in {duration:.4f}ms\n")
  run.appendOutput(fullOutput)

proc renderSuiteResults(
    suiteItem: VscodeTestItem, res: RunTestProjectResult, run: VscodeTestRun) =
  ## Match test results into a suite item's children by label.
  for suite in res.suites:
    suiteItem.children.forEach(proc(testItem: VscodeTestItem) =
      for testResult in suite.testResults:
        if testItem.label == testResult.name:
          renderTestResult(testItem, testResult, run, res.fullOutput)
    )

proc renderProjectResults(
    projItem: VscodeTestItem, res: RunTestProjectResult, run: VscodeTestRun) =
  ## Match suite results into a project item's children by label,
  ## then delegate to renderSuiteResults for the test level.
  for suite in res.suites:
    projItem.children.forEach(proc(suiteItem: VscodeTestItem) =
      if suiteItem.label == suite.name:
        renderSuiteResults(suiteItem, res, run)
    )

# --- single test run ---------------------------------------------------------

proc runSingleTest(
    item: VscodeTestItem, run: VscodeTestRun,
    token: VscodeCancellationToken = nil) =
  let state = ext
  let id = $item.id
  let ep = itemEntryPoint.getOrDefault(item.id, "")
  if ep == "": return

  run.started(item)

  if not token.isNil and token.isCancellationRequested:
    run.skipped(item)
    run.`end`()
    return

  var runParams = RunTestParams(entryPoint: ep)
  if id.startsWith("s:"):
    runParams.suiteName = item.label
  elif id.startsWith("t:"):
    runParams.suiteName = itemSuiteName.getOrDefault(item.id, "")
    runParams.testNames = @[item.label]
  # "p:" prefix: no filter — run everything for this entry point

  let runTestRes = requestRunTest(state, runParams)
  runTestRes.then(proc(res: RunTestProjectResult) =
    if id.startsWith("p:"):
      renderProjectResults(item, res, run)
    elif id.startsWith("s:"):
      renderSuiteResults(item, res, run)
    else:
      if res.suites.len > 0 and res.suites[0].testResults.len > 0:
        renderTestResult(item, res.suites[0].testResults[0], run, res.fullOutput)
    run.`end`()
  )
  runTestRes.catch(proc(err: ref Exception) =
    console.log("Run test error: ", err)
    run.failed(item, VscodeTestMessage(message: err.msg), duration = 0)
    run.`end`()
  )

# --- run-all (multiple entry points) -----------------------------------------

proc launchEpRun(
    state: ExtensionState, ep: cstring,
    run: VscodeTestRun, remaining: ref int) =
  ## Fire a runTests request for one entry point.
  ## Decrements `remaining` and calls run.end() when all are done.
  ## Using a helper proc (rather than an inline closure in a loop) guarantees
  ## each iteration captures its own copy of `ep` and `projId`.
  let projId = projectId(ep)
  let runParams = RunTestParams(entryPoint: ep)
  let runTestRes = requestRunTest(state, runParams)
  runTestRes.then(proc(res: RunTestProjectResult) =
    testController.getItems().forEach(proc(projItem: VscodeTestItem) =
      if projItem.id == projId:
        renderProjectResults(projItem, res, run)
    )
    dec remaining[]
    if remaining[] == 0:
      run.`end`()
  )
  runTestRes.catch(proc(err: ref Exception) =
    console.log("Run test error for entry point ", ep, ": ", err)
    dec remaining[]
    if remaining[] == 0:
      run.`end`()
  )

proc runAllTests(
    request: VscodeTestRunRequest, run: VscodeTestRun,
    token: VscodeCancellationToken = nil) =
  let state = ext
  let entryPoints = getEntryPoints(state)

  if not token.isNil and token.isCancellationRequested:
    run.`end`()
    return

  if entryPoints.len == 0:
    run.`end`()
    return

  # Mark every visible item as started upfront.
  testController.getItems().forEach(proc(projItem: VscodeTestItem) =
    run.started(projItem)
    projItem.children.forEach(proc(suiteItem: VscodeTestItem) =
      run.started(suiteItem)
      suiteItem.children.forEach(proc(testItem: VscodeTestItem) =
        run.started(testItem)
      )
    )
  )

  var remaining = new(int)
  remaining[] = entryPoints.len
  for ep in entryPoints:
    launchEpRun(state, ep, run, remaining)

# --- run handler (VS Code TestRunProfile callback) ---------------------------

proc runHandler(request: VscodeTestRunRequest, token: VscodeCancellationToken) =
  let isRunAll = request.include.isUndefined
  let run = testController.createTestRun(request)

  token.onCancellationRequested(proc() {.async.} =
    let state = ext
    let cancelTestRes = await requestCancelTest(state)
    if cancelTestRes.cancelled:
      let allTests = if isRunAll: testController.getItems() else: request.include
      allTests.forEach(proc(item: VscodeTestItem) =
        run.skipped(item)
        item.children.forEach(proc(suiteItem: VscodeTestItem) =
          run.skipped(suiteItem)
          suiteItem.children.forEach(proc(testItem: VscodeTestItem) =
            run.skipped(testItem)
          )
        )
      )
      run.`end`()
  )

  if isRunAll:
    runAllTests(request, run, token)
  else:
    request.include.forEach(proc(item: VscodeTestItem) =
      runSingleTest(item, run, token)
    )

# --- test discovery ----------------------------------------------------------

proc loadTests(state: ExtensionState, isRefresh: bool = false): Future[void] {.async.} =
  if excRunTests notin state.lspExtensionCapabilities:
    console.log("Run tests capability not found")
    return

  let entryPoints = getEntryPoints(state)
  if entryPoints.len == 0:
    outputLine("No test entry points configured. Set nimTortoise.test.entryPoints in settings.")
    return

  testController.getItems().clear()
  itemEntryPoint.clear()
  itemSuiteName.clear()

  var anyError = false
  var totalSuites = 0

  for ep in entryPoints:
    let listRes = await fetchListTests(state, ListTestsParams(entryPoint: ep))

    if listRes.projectInfo.error != nil:
      vscode.window.showErrorMessage(
        "Error loading tests for " & $ep & " (see lsp output):\n" & listRes.projectInfo.error
      )
      anyError = true
      continue

    let projItem = testController.createTestItem(projectId(ep), getProjectLabel(ep))
    itemEntryPoint[projectId(ep)] = ep

    for key, suite in listRes.projectInfo.suites:
      let sid = suiteId(ep, suite.name)
      let suiteItem = testController.createTestItem(sid, suite.name)
      itemEntryPoint[sid] = ep
      for test in suite.tests:
        let tid = testId(ep, suite.name, test.name)
        let testItem = testController.createTestItem(tid, test.name)
        itemEntryPoint[tid] = ep
        itemSuiteName[tid] = suite.name
        suiteItem.children.add(testItem)
      projItem.children.add(suiteItem)
      inc totalSuites

    testController.getItems().add(projItem)

  if runProfile.isNil and not anyError:
    runProfile = testController.createRunProfile(
      "Run Tests", VscodeTestRunProfileKind.Run, runHandler, true
    )

  if not anyError:
    if totalSuites == 0:
      vscode.window.showInformationMessage("No tests found for the configured entry points.")
    elif isRefresh:
      vscode.window.showInformationMessage("Tests refreshed successfully")
    else:
      vscode.window.showInformationMessage("Tests loaded successfully")

# --- public API --------------------------------------------------------------

proc refreshTests*() {.async.} =
  if testController.isNil:
    testController = vscode.tests.createTestController("nim-tests".cstring, "Nim Tests".cstring)
  try:
    await loadTests(ext, true)
  except:
    vscode.window.showErrorMessage("Failed to refresh tests: " & getCurrentExceptionMsg())

proc initializeTests*(context: VscodeExtensionContext, state: ExtensionState) =
  proc onExtensionReady() =
    proc inner() {.async.} =
      testController = vscode.tests.createTestController("nim-tests".cstring, "Nim Tests".cstring)
      testController.refreshHandler = proc() =
        discard refreshTests()
      await loadTests(state)
      context.subscriptions.add(testController)
    discard inner()
  state.onExtensionReadyHooks.add(onExtensionReady)
