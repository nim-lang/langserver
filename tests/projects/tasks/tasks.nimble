# Package

version       = "0.1.0"
author        = "jmgomez"
description   = "A new awesome nimble package"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["tasks"]


# Dependencies

requires "nim >= 2.1.99"

task helloWorld, "hello world":
  echo "helo world"

task anotherTask, "Another task":
  echo "another task"