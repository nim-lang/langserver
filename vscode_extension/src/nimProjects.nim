# modules handles the concept of nim projects. Projects are the project file
# we pass to the compiler, nimsuggest, etc... 

from platform/vscodeApi import
  VscodeWorkspaceFolder, VscodeWorkspaceConfiguration, vscode, getWorkspaceFolder,
  uriFile, asRelativePath, findFiles, get, newWorkspaceFolderLike, VscodeUri,
  VscodeUriChange, with, getConfiguration, VscodeConfigurationChangeEvent,
  affectsConfiguration
import std/[jsconsole, jsffi]
import platform/js/[jsPromise, jsString, jsNode, jsre]
from platform/js/jsNodePath import path, isAbsolute, parse, ParsedPath, dirname

type
  ProjectFileInfo* = ref object
    wsFolder*: VscodeWorkspaceFolder
    filePath*: cstring

  ProjectMappingInfo* = ref object
    fileRegex*: RegExp
    projectPath*: cstring

var
  projects = newArray[ProjectFileInfo]()
  projectMapping = newArray[ProjectMappingInfo]()

proc getProjects*(): Array[ProjectFileInfo] =
  projects

proc isProjectMode*(): bool =
  projects.len > 0

proc toProjectInfo(filePath: cstring): ProjectFileInfo =
  var workspace = vscode.workspace
  if path.isAbsolute(filePath):
    var workspaceFolder = workspace.getWorkspaceFolder(vscode.uriFile(filePath))
    if workspaceFolder.toJs().to(bool):
      return ProjectFileInfo{
        wsFolder: workspaceFolder, filePath: workspace.asRelativePath(filePath, false)
      }
  elif workspace.workspaceFolders.toJs().to(bool) and workspace.workspaceFolders.len > 0:
    var workspaceFolders = workspace.workspaceFolders
    if workspaceFolders.len == 1:
      return ProjectFileInfo{wsFolder: workspaceFolders[0], filePath: filePath}
    else:
      var parsedPath: seq[cstring] = filePath.split("/")
      if parsedPath.len > 1:
        for folder in workspaceFolders:
          if parsedPath[0] == folder.name:
            return ProjectFileInfo{
              wsFolder: folder,
              filePath: filePath[parsedPath[0].len + 1 ..< filePath.len],
            }

  var parsedPath = path.parse(filePath)
  return ProjectFileInfo{
    wsFolder:
      newWorkspaceFolderLike(vscode.uriFile(parsedPath.dir), cstring("root"), cint(0)),
    filePath: parsedPath.base,
  }

proc toLocalFile*(project: ProjectFileInfo): cstring =
  ## Returns a project file's file system path string
  return project.wsFolder.uri.with(
    VscodeUriChange{path: project.wsFolder.uri.path & "/" & project.filePath}
  ).fsPath

proc getProjectFileInfo*(filename: cstring): ProjectFileInfo =
  if not isProjectMode():
    var projectInfo: ProjectFileInfo
    if projectMapping.len > 0:
      var uriPath = vscode.uriFile(filename).path
      for mapping in projectMapping:
        if mapping.fileRegex.test(uriPath):
          continue
        projectInfo =
          toProjectInfo(uriPath.replace(mapping.fileRegex, mapping.projectPath))
        break
    if projectInfo.isNil():
      projectInfo = toProjectInfo(filename)
    return projectInfo

  for project in projects:
    if filename.startsWith(path.dirname(toLocalFile(project))):
      return project
  return projects[0]

proc processConfigProjects(conf: JsObject): void =
  ## updates `projects` from config `nim.projects`, if `nim.projects` changed
  ## ensure that process `processConfigProjectMapping` is called thereafter
  projects.setLen(0)

  if conf.to(bool):
    if conf.isJsArray:
      for p in conf.to(seq[cstring]):
        projects.add(toProjectInfo(p))
    else:
      vscode.workspace
      .findFiles(conf.to(cstring))
      .then(
        proc(res: Array[VscodeUri]) =
          if res.toJs.to(bool) and res.len > 0:
            projects.add(toProjectInfo(res[0].fsPath))
      )
      .catch(
        proc(reason: JsObject) =
          console.error("nimProjects - processConfigProjects Failed", reason)
      )

proc processConfigProjectMapping(conf: JsObject): void =
  ## updates `projectMapping` from config `nim.projectMapping`, if
  ## `nim.projects` changed ensure that `procesConfigProjects` is called first

  projectMapping.setLen(0)

  if not conf.to(bool) and conf.jsTypeOf() == "object":
    for k in keys(conf):
      let path = conf[k].to(cstring)
      projectMapping.add(
        ProjectMappingInfo{
          fileRegex: newRegExp(k.toJs().to(cstring), ""), projectPath: path
        }
      )

proc processConfig*(conf: VscodeWorkspaceConfiguration): void =
  ## to be called whenever the config updates and on initial startup

  var
    cfgProjects = conf.get("project")
    cfgMappings = conf.get("projectMapping")

  processConfigProjects(cfgProjects)
  processConfigProjectMapping(cfgMappings)

proc configUpdate*(cfgChg: VscodeConfigurationChangeEvent): void =
  let
    projectsChanged = cfgChg.affectsConfiguration("nim.project")
    mappingsChanged = cfgChg.affectsConfiguration("nim.projectMapping")
    conf = vscode.workspace.getConfiguration("nim")

  if projectsChanged:
    processConfigProjects(conf.get("project"))
  if mappingsChanged:
    processConfigProjectMapping(conf.get("projectMapping"))
