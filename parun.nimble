# Package

version = "0.1.0"
author = "Gabriel Capilla"
description = "Terminal UI for paru or pacman"
license = "MIT"
srcDir = "src"
bin = @["parun"]

# Dependencies

requires "nim >= 2.2.6"

task r, "Build release":
  exec "nimble --verbose run -d:release"

task b, "Build release":
  exec "nimble --verbose build -d:release"

task c, "Clean binary":
  exec "nimble clean"
