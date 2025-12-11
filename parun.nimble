# Package

version = "0.1.5"
author = "Gabriel Capilla"
description = "Terminal UI for paru or pacman"
license = "MIT"
srcDir = "src"
bin = @["parun"]

# Dependencies

requires "nim >= 2.2.6"
requires "nimsimd >= 1.2.0"

# Tasks

task r, "Build release":
  exec "nimble --verbose run -d:release -d:danger --passC:-msse2"

task b, "Build release":
  exec "nimble --verbose build -d:release -d:danger --passC:-msse2"

task c, "Clean binary":
  exec "nimble clean"
