import platform/vscodeApi
import std/[strformat, jsconsole, tables, options, sequtils]
import spec, nimLsp
import platform/js/jsNodeFs
import nimProjects
import nimUtils

var testController: VscodeTestController
var runProfile: VscodeTestRunProfile = nil

#[
run.started(test) - Mark a test as running
run.passed(test, ?message) - Mark a test as passed
run.failed(test, ?message) - Mark a test as failed
run.errored(test, ?message) - Mark a test as errored
run.skipped(test) - Mark a test as skipped
run.appendOutput(content) - Add output text to the test run
run.end() - Complete the test run
]#

#Basically in nim you will be able to run all tests a suite, or a single test

proc isSuite(test: VscodeTestItem): bool =
  return test.children.size() > 0

proc renderTestResult(test: VscodeTestItem, result: RunTestResult, run: VscodeTestRun, fullOutput: cstring = "") =
  console.log("Rendering test result: ", result)
  let duration = result.time * 1000
  console.log("Duration: ", duration)
  if result.failure.isNull:
    run.passed(test, duration = duration)
    run.appendOutput(&"[{test.label}] Test passed in {duration:.4f}ms\n")
  else:
    run.failed(test, VscodeTestMessage(message: result.failure), duration = duration)  # Use time directly
    run.appendOutput(&"[{test.label}] Test failed with error:\n")    
    run.appendOutput(result.failure)
    run.appendOutput(&"[{test.label}] Test failed in {duration:.4f}ms\n")
  
  run.appendOutput(fullOutput)


proc renderTestProjectResult(projectResult: RunTestProjectResult, run: VscodeTestRun, testCol: Option[VscodeTestItemCollection]) =
  for suite in projectResult.suites:
    for testResult in suite.testResults:
      if testCol.isSome:
        # Find the child test item that matches this result
        testCol.get.forEach(proc(childTest: VscodeTestItem) =
          if childTest.id == testResult.name:
            renderTestResult(childTest, testResult, run, projectResult.fullOutput)
          childTest.children.forEach(proc(childChildTest: VscodeTestItem) =
            if childChildTest.id == testResult.name:
              renderTestResult(childChildTest, testResult, run, projectResult.fullOutput)
          )
          )

proc getEntryPoint(state: ExtensionState): Option[cstring] =
  var entryPoint = state.config.getStr("test.entryPoint")
  result = none cstring
  if entryPoint == "":
    entryPoint = state.dumpTestEntryPoint
    if entryPoint != "":
      console.log("Using test entry point from nimble dump: ", entryPoint)
      result = some entryPoint
    else:
      outputLine("No test entry point found")
      result = none cstring
  else:
    result = some entryPoint

proc runSingleTest(test: VscodeTestItem, run: VscodeTestRun, token: VscodeCancellationToken = nil) = 
  let state = ext
  let entryPoint = getEntryPoint(state)
  if entryPoint.isNone:
    return
  run.started(test)
  console.log("Running test: ", test.id)
  var runTestParams = RunTestParams(entryPoint: entryPoint.get())
  if test.isSuite:
    runTestParams.suiteName = test.id
  else:
    runTestParams.testNames = @[test.id]

  # Check if cancelled before starting
  if not token.isNil and token.isCancellationRequested:
    run.skipped(test)
    run.`end`()
    return

  let runTestRes = requestRunTest(state, runTestParams)
  runTestRes.then(proc(res: RunTestProjectResult) =
    if test.isSuite:
      renderTestProjectResult(res, run, some test.children)
    else:
      renderTestResult(test, res.suites[0].testResults[0], run, res.fullOutput)
    run.`end`()
  )
  runTestRes.catch(proc(err: ref Exception) =
    console.log("Run test error: ", err)
    run.failed(test, VscodeTestMessage(message: err.msg), duration = 0)
    run.`end`()
  )

proc runAllTests(request: VscodeTestRunRequest, run: VscodeTestRun, token: VscodeCancellationToken = nil) =
  let state = ext
  let entryPoint = state.config.getStr("test.entryPoint")  
  
  # Check if cancelled before starting
  if not token.isNil and token.isCancellationRequested:
    run.`end`()
    return
    
  testController.getItems().forEach(proc(item: VscodeTestItem) =
    run.started(item)
    item.children.forEach(proc(child: VscodeTestItem) =
      run.started(child)
    )
  )
  
  var runTestParams = RunTestParams(entryPoint: entryPoint)
  let runTestRes = requestRunTest(state, runTestParams)
  runTestRes.then(proc(res: RunTestProjectResult) =
    console.log("Run test result: ", res)
    renderTestProjectResult(res, run, some testController.getItems())
    run.`end`()
  )
  runTestRes.catch(proc(err: ref Exception) =
    console.log("Run test error: ", err)
    testController.getItems().forEach(proc(item: VscodeTestItem) =
      run.failed(item, VscodeTestMessage(message: err.msg), duration = 0)
    )
    run.`end`())

proc runHandler(request: VscodeTestRunRequest, token: VscodeCancellationToken) =
  console.log("Running tests...", request)
  let isRunAll = request.include.isUndefined
  console.log("Is run all: ", isRunAll)
  let run = testController.createTestRun(request)

  # Subscribe to cancellation
  token.onCancellationRequested(proc() {.async.} =
    #Call to the lsp to cancel the test run
    console.log("Test run was cancelled")
    let state = ext
    let cancelTestRes = await requestCancelTest(state)
    console.log("Cancelled test result: ", cancelTestRes)
    if cancelTestRes.cancelled:
      let allTests = if isRunAll: testController.getItems() else: request.include
      allTests.forEach(proc(item: VscodeTestItem) =
        run.skipped(item)
        if item.isSuite:
          item.children.forEach(proc(child: VscodeTestItem) =
            run.skipped(child)
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

proc loadTests(state: ExtensionState, isRefresh: bool = false): Future[void] {.async.} =
  if excRunTests notin state.lspExtensionCapabilities:
    console.log("Run tests capability not found")
    return
    
  let entryPoint = getEntryPoint(state)
  if entryPoint.isNone:
    console.log("No entry point found")
    return
  let listTestsParams = ListTestsParams(entryPoint: entryPoint.get())
  testController.getItems().clear()
  console.log("Fetching tests")
  let listTestsRes = await fetchListTests(state, listTestsParams)
  console.log("Tests fetched", listTestsRes)
  
  if listTestsRes.projectInfo.error != nil:
    vscode.window.showErrorMessage("There was an issue trying to load the tests (see lsp output for more details): \n" & listTestsRes.projectInfo.error)
    # Remove the run profile if it exists
    if not runProfile.isNil:
      runProfile.dispose()
      runProfile = nil
    return

  # Create run profile only if it doesn't exist
  if runProfile.isNil:
    runProfile = testController.createRunProfile(
      "Run Tests",
      VscodeTestRunProfileKind.Run,
      runHandler,
      true
    )

  if isRefresh:
    vscode.window.showInformationMessage("Tests refreshed successfully")
  else:
    vscode.window.showInformationMessage("Tests loaded successfully")

  if listTestsRes.projectInfo.suites.keys.toSeq.len == 0:
    vscode.window.showInformationMessage("No tests found for entry point: " & entryPoint.get())
    # Don't return here, let it continue to clear any existing error items
  
  console.log("Loading tests", listTestsRes.projectInfo)
  # Load test items
  for key, suite in listTestsRes.projectInfo.suites:
    let suiteItem = testController.createTestItem(suite.name, suite.name)
    console.log("Suite item", suiteItem)
    for test in suite.tests:
      let testItem = testController.createTestItem(test.name, test.name)
      console.log("Test item", testItem)
      suiteItem.children.add(testItem)
    testController.getItems().add(suiteItem)

proc refreshTests*() {.async.} =
  if testController.isNil:
    testController = vscode.tests.createTestController("nim-tests".cstring, "Nim Tests".cstring)    
    
  try:
    console.log("Refreshing tests")
    let state = ext
    await loadTests(state, true)
  except:
    let msg = getCurrentExceptionMsg()
    vscode.window.showErrorMessage("Failed to refresh tests: " & msg)

proc initializeTests*(context: VscodeExtensionContext, state: ExtensionState) =
  proc onExtensionReady() =
    proc inner() {.async.} =
      testController = vscode.tests.createTestController("nim-tests".cstring, "Nim Tests".cstring)
      
      testController.refreshHandler = proc() =
        discard refreshTests()
      
      await loadTests(state)
      
      # Initial run profile creation moved to loadTests
      context.subscriptions.add(testController)
    discard inner()

  state.onExtensionReadyHooks.add(onExtensionReady)
