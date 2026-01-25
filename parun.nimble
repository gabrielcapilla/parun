# Package

version = "0.5.0"
author = "Gabriel Capilla"
description = "Terminal UI for pacman, AUR & nimble"
license = "MIT"
srcDir = "src"
bin = @["parun"]

# Dependencies

requires "nim >= 2.2.6"

# Tasks

task release, "Build optimized release binary":
  exec "nimble build -d:release"
