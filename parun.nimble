# Package

version = "0.3.0"
author = "Gabriel Capilla"
description = "Terminal UI for pacman, AUR & nimble"
license = "MIT"
srcDir = "src"
bin = @["parun"]

# Dependencies

requires "nim >= 2.2.6"
requires "nimsimd >= 1.3.2"

# Tasks

task release, "Build optimized release binary":
  exec "nimble build -d:release -d:danger -d:lto -d:strip --d:ssl --passC:-msse2 --verbose"
