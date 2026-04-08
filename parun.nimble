# Package

version       = "0.6.0"
author        = "Gabriel Capilla"
description   = "Terminal UI for pacman, AUR & nimble"
license       = "MIT"
srcDir        = "src"
bin           = @["parun"]

# Dependencies

requires "nim >= 2.2.6"

# Tasks

task release, "Build deterministic release binary for public distribution":
  exec "nimble build -d:release"

task releaseNative, "Build host-optimized binary for local use only":
  exec "nimble build -d:release --passC:-march=native"
