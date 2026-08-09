import std/strformat
# Package

version = "0.1.2"
author = "David Pocknee"
description = "The VS Code extension for the Nim Tortoise Language Server, a Language Server for nim that prioritises correctness over speed."
license = "MIT"
backend = "js"
srcDir = "src"
binDir = "out"
bin = @["vscode_nim_tortoise"]

# Deps

requires "nim >= 2.0.0 & <= 2.1"

import std/os

proc initialNpmInstall() =
  if not dirExists "node_modules":
    exec "npm install"

# Tasks
task main, "This compiles the vscode Nim extension":
  exec "nim js --outdir:out --checks:on --sourceMap src/vscode_nim_tortoise.nim"

task release, "This compiles a release version":
  exec "nim js -d:release -d:danger --outdir:out --checks:off --sourceMap src/vscode_nim_tortoise.nim"

task vsix, "Build VSIX package":
  initialNpmInstall()
  var cmd = "npm exec -c 'vsce package --out out/vscode_nim_tortoise-" & version & ".vsix'"
  when defined(windows):
    cmd = "powershell.exe " & cmd
  exec cmd

task install_vsix, "Install the VSIX package":
  initialNpmInstall()
  exec "code --install-extension out/vscode_nim_tortoise-" & version & ".vsix"

# Tasks for maintenance
# task audit_node_deps, "Audit Node.js dependencies":
#   initialNpmInstall()
#   exec "npm audit"
#   echo "NOTE: 'engines' versions in 'package.json' need manually audited"

# task upgrade_node_deps, "Upgrade Node.js dependencies":
#   initialNpmInstall()
#   exec "npm exec -c 'ncu -ui'"
#   exec "npm install"
#   echo "NOTE: 'engines' versions in 'package.json' need manually upgraded"

# # Tasks for publishing the extension
# task extReleasePatch, "Patch release on vscode marketplace and openvsx registry":
#   initialNpmInstall()
#   exec "npm exec -c 'vsce publish patch'" # this bumps the version number
#   exec "npm exec -c 'ovsx publish " & out/nimvscode-" & version & ".vsix & "'"
