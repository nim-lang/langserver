## supports auto-completion of module imports... this feels a bit janky

import platform/vscodeApi
import platform/js/[jsNodeCp, jsNodeFs, jsNodePath, jsString, jsre]
import std/jsconsole

from nimProjects import getProjects, isProjectMode
from tools/nimBinTools import getNimExecPath, getNimbleExecPath

type
  NimbleModuleInfo = ref object
    name*: cstring
    author*: cstring
    description*: cstring
    version*: cstring

  NimModuleInfo = ref NimModuleInfoObj
  NimModuleInfoObj {.importc.} = ref object of JsRoot
    name*: cstring
    fullName*: cstring
    path*: cstring

var nimbleModules: seq[NimbleModuleInfo] = @[]
var nimModules = newJsAssoc[cstring, seq[NimModuleInfo]]()

proc getNimDirectories(
    projectDir: cstring, projectFile: cstring
): Promise[seq[cstring]] =
  return newPromise(
    proc(resolve: proc(v: seq[cstring]), reject: proc(reasons: JsObject)) =
      let execPath = getNimExecPath()
      if execPath.isNil() or execPath.strip() == "":
        vscode.window.showInformationMessage(
          "Binary named 'nim' not found in PATH environment variable"
        )
        resolve(@[])
        return

      discard cp.exec(
        execPath & " dump " & projectFile,
        ExecOptions{cwd: projectDir},
        proc(err: ExecError, stdout: cstring, stderr: cstring): void =
          var res: seq[cstring] = @[]
          var parts = stderr.split("\n")
          for part in parts:
            var p = part.strip()
            if p.len > 0 and not p.startsWith("Hint: "):
              res.add(p)
          resolve(res),
      )
  )

proc createNimModule(
    projectDir: cstring, rootDir: cstring, dir: cstring, file: cstring
): NimModuleInfo =
  var nimModule =
    NimModuleInfo{name: file[0 .. (file.len - 5)], path: path.join(dir, file)}
  if dir.len > rootDir.len:
    var moduleDir = dir[(rootDir.len + 1) .. (dir.len - 1)].replace(path.sep, ".")
    nimModule.fullName = moduleDir & "." & nimModule.name
  else:
    nimModule.fullName = nimModule.name

  return nimModule

proc walkDir(
    projectDir: cstring, rootDir: cstring, dir: cstring, singlePass: bool
): void =
  fs.readdir(
    dir,
    proc(err: ErrnoException, files: seq[cstring]) =
      # if files.toJs().to(bool):
      for file in files:
        var fullPath = path.join(dir, file)
        if fs.statSync(fullPath).isDirectory():
          if not singlePass:
            walkDir(projectDir, rootDir, fullPath, false)
        elif file.toLowerAscii().endsWith(".nim"):
          var mods = nimModules[projectDir]
          mods.add(createNimModule(projectDir, rootDir, dir, file))
          nimModules[projectDir] = mods,
  )

proc initNimDirectories(projectDir: cstring, projectFile: cstring): Promise[void] =
  if nimModules[projectDir].toJs().to(bool):
    nimModules[projectDir] = @[]
    let
      execPath = getNimExecPath()
      nimRoot = path.dirname(path.dirname(execPath))

    # we check this after setting `nimRoot`, but it shouldn't matter
    if execPath.isNil() or execPath.strip() == "":
      vscode.window.showInformationMessage(
        "Binary named 'nim' not found in PATH environment variable"
      )
      return

    getNimDirectories(projectDir, projectFile)
    .then(
      proc(dirs: seq[cstring]) =
        for dir in dirs:
          walkDir(projectDir, dir, dir, dir.startsWith(nimRoot))
    )
    .toJs()
    .to(Promise[void])
  else:
    newEmptyPromise()

proc getNimbleModules(rootDir: cstring): Promise[seq[cstring]] =
  return newPromise(
    proc(resolve: proc(v: seq[cstring]), reject: proc(reasons: JsObject)) =
      discard cp.exec(
        getNimbleExecPath() & " list -i",
        ExecOptions{cwd: rootDir},
        proc(err: ExecError, stdout: cstring, stderr: cstring): void =
          var res: seq[cstring] = @[]
          var parts = stdout.split("\n")
          for part in parts:
            var p = part.split("[")[0].strip()
            if p.len > 0 and p != "compiler".cstring:
              res.add(p)
          resolve(res),
      )
  )

proc initNimbleModules(rootDir: cstring): Promise[seq[cstring]] =
  getNimbleModules(rootDir)
  .then(
    proc(nimbleModuleNames: seq[cstring]) =
      for moduleName in nimbleModuleNames:
        try:
          var output: cstring = cp
            .execSync(
              getNimbleExecPath() & " --y dump " & moduleName, ExecOptions{cwd: rootDir}
            )
            .toString()
          var nimbleModule = NimbleModuleInfo{name: moduleName}
          for line in output.split(newRegExp(r"\n", "")):
            var pairs = line.strip().split(": \"")
            if pairs.len == 2:
              var value = pairs[1][0 .. (pairs[1].len - 2)]
              case $(pairs[0])
              of "author":
                nimbleModule.author = value
              of "version":
                nimbleModule.version = value
              of "desc":
                nimbleModule.description = value
          nimbleModules.add(nimbleModule)
        except:
          console.log(
            "Module incorrect " & moduleName, getCurrentExceptionMsg().cstring
          )
  )
  .toJs()
  .to(Promise[seq[cstring]])

proc getImports*(prefix: cstring, projectDir: cstring): seq[VscodeCompletionItem] =
  console.log("getImports", jsArguments)
  var suggestions: seq[VscodeCompletionItem] = @[]
  for nimbleModule in nimbleModules:
    if prefix.isNil() or nimbleModule.name.startsWith(prefix):
      var suggestion =
        vscode.newCompletionItem(nimbleModule.name, VscodeCompletionKind.module)
      if not nimbleModule.version.isNil():
        suggestion.detail = nimbleModule.name & "[" & nimbleModule.version & "]"
      else:
        suggestion.detail = nimbleModule.name

      suggestion.detail &= " (Nimble)"
      var doc = "**Name**: " & nimbleModule.name
      if nimbleModule.version.toJs().to(bool):
        doc &= "\n\n**Version**: " & nimbleModule.version
      if nimbleModule.author.toJs().to(bool):
        doc &= "\n\n**Author**: " & nimbleModule.author
      if nimbleModule.description.toJs().to(bool):
        doc &= "\n\n**Description**: " & nimbleModule.description
      suggestion.documention = vscode.newMarkdownString(doc)
      suggestions.add(suggestion)
    if suggestions.len >= 20:
      return suggestions
  if nimModules[projectDir].toJs().to(bool):
    for nimModule in nimModules[projectDir]:
      if not prefix.isNil() or nimModule.name.startsWith(prefix):
        var suggest =
          vscode.newCompletionItem(nimModule.name, VscodeCompletionKind.module)
        suggest.insertText = nimModule.fullName
        suggest.detail = nimModule.fullName
        suggest.insertText = nimModule.path
        suggestions.add(suggest)
      if suggestions.len >= 100:
        return suggestions
  return suggestions

proc initImports*(): Promise[void] =
  var folders = vscode.workspace.workspaceFolders
  var prevPromise: Promise[void] = newEmptyPromise()
  if folders.toJs().to(bool):
    prevPromise = initNimbleModules(folders[0].uri.fsPath).toJs().to(Promise[void])

  if isProjectMode():
    for project in getProjects():
      prevPromise = prevPromise.then(
        proc() =
          discard initNimDirectories(project.wsFolder.uri.fsPath, project.filePath)
      )
  elif folders.toJs().to(bool):
    prevPromise.then(
      proc() =
        discard initNimDirectories(folders[0].uri.fsPath, "")
    )

  return prevPromise

proc addFileToImports*(file: cstring): Promise[void] =
  if isProjectMode():
    for project in getProjects():
      var projectDir = project.wsFolder.uri.fsPath
      if file.startsWith(projectDir):
        var mods = nimModules[projectDir]
        if not mods.toJs().to(bool):
          mods = @[]

        mods.add(
          createNimModule(
            projectDir, projectDir, path.dirname(file), path.basename(file)
          )
        )

        nimModules[projectDir] = mods
  elif vscode.workspace.workspaceFolders.toJs().to(bool):
    var projectDir = vscode.workspace.workspaceFolders[0].uri.fsPath
    var mods = nimModules[projectDir]
    if not mods.toJs().to(bool):
      mods = @[]
    mods.add(
      createNimModule(projectDir, projectDir, path.dirname(file), path.basename(file))
    )

    nimModules[projectDir] = mods

  return newEmptyPromise()

proc splice[T](x: seq[T], n: cint): void {.importcpp.}

proc removeFileFromImports*(file: cstring): Promise[void] =
  for key, items in nimModules:
    var i: cint = 0
    while i < items.len:
      if items[i].path == file:
        items.splice(i)
      else:
        inc i

  return newEmptyPromise()
