# Package

version = "0.2.0"
author = "Gabriel Capilla"
description = "Terminal UI for pacman, AUR & nimble"
license = "MIT"
srcDir = "src"
bin = @["parun"]

# Dependencies

requires "nim >= 2.2.6"
requires "nimsimd >= 1.3.2"

# Tests

task test_01, "Run the stress test":
  exec "nim compile --run tests/test_01.nim"

task test_02, "Run the memory test":
  exec "nim compile --run tests/test_02.nim"

# Tasks

task release, "Build optimized release binary":
  exec "nimble build -d:release -d:danger -d:lto -d:strip --passC:-msse2 --verbose"
  exec "cp parun $HOME/.local/bin"

task c, "Clean binary":
  exec "nimble clean"
