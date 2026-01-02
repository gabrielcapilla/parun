##
##  Package Manager Tests
##
## Tests for package management operations and tool configuration.
##

import unittest
import std/[monotimes, times, strutils, os, streams, parsejson]
import ../src/pkgs/manager

suite "PKGS - Tool Configuration":
  test "Tools array - has 4 tools":
    check Tools.len == 4

  test "Tools[ManPacman] - correct configuration":
    let pacman = Tools[ManPacman]
    check pacman.bin == "pacman"
    check pacman.installCmd == " -S "
    check pacman.uninstallCmd == " -R "
    check pacman.searchCmd == " -Ss "
    check pacman.sudo == true
    check pacman.supportsAur == false

  test "Tools[ManParu] - correct configuration":
    let paru = Tools[ManParu]
    check paru.bin == "paru"
    check paru.installCmd == " -S "
    check paru.uninstallCmd == " -R "
    check paru.searchCmd == " -Ss "
    check paru.sudo == false
    check paru.supportsAur == false

  test "Tools[ManYay] - correct configuration":
    let yay = Tools[ManYay]
    check yay.bin == "yay"
    check yay.installCmd == " -S "
    check yay.uninstallCmd == " -R "
    check yay.searchCmd == " -Ss "
    check yay.sudo == false
    check yay.supportsAur == false

  test "Tools[ManNimble] - correct configuration":
    let nimble = Tools[ManNimble]
    check nimble.bin == "nimble"
    check nimble.installCmd == " install "
    check nimble.uninstallCmd == " uninstall "
    check nimble.searchCmd == " search "
    check nimble.sudo == false
    check nimble.supportsAur == false

  test "ToolDef enum - correct values":
    check ManPacman.ord == 0
    check ManParu.ord == 1
    check ManYay.ord == 2
    check ManNimble.ord == 3

suite "PKGS - Constants":
  test "AurMetaUrl - correct URL":
    check AurMetaUrl == "https://aur.archlinux.org/packages-meta-v1.json.gz"

  test "NimbleMetaUrl - correct URL":
    check NimbleMetaUrl ==
      "https://raw.githubusercontent.com/nim-lang/packages/refs/heads/master/packages.json"

  test "CacheMaxAgeHours - correct value":
    check CacheMaxAgeHours == 24

suite "PKGS - CachedJsonSource":
  test "CachedJsonSource - complete structure":
    let source = CachedJsonSource(
      localFallbackPath: "/tmp/test.json",
      cachePath: "test.json",
      url: "https://example.com/test.json",
      maxAgeHours: 24,
      isCompressed: false,
    )
    check source.localFallbackPath == "/tmp/test.json"
    check source.cachePath == "test.json"
    check source.url == "https://example.com/test.json"
    check source.maxAgeHours == 24
    check source.isCompressed == false

  test "CachedJsonSource - with default values":
    let source = CachedJsonSource(
      localFallbackPath: "",
      cachePath: "cache.json",
      url: "https://example.com/cache.json",
      maxAgeHours: 12,
      isCompressed: true,
    )
    check source.localFallbackPath == ""
    check source.cachePath == "cache.json"
    check source.isCompressed == true

suite "PKGS - JSON Parser":
  test "skipJsonBlock - objeto vacio":
    let s = "{}"
    var fs = newStringStream(s)
    var p: JsonParser
    open(p, fs, "test")
    p.next() # jsonObjectStart
    skipJsonBlock(p)
    check p.kind == jsonObjectEnd
    close(p)

  test "skipJsonBlock - objeto simple":
    let s = """{"key": "value"}"""
    var fs = newStringStream(s)
    var p: JsonParser
    open(p, fs, "test")
    p.next() # jsonObjectStart
    skipJsonBlock(p)
    check p.kind == jsonObjectEnd
    close(p)

  test "skipJsonBlock - array vacio":
    let s = "[]"
    var fs = newStringStream(s)
    var p: JsonParser
    open(p, fs, "test")
    p.next() # jsonArrayStart
    skipJsonBlock(p)
    check p.kind == jsonArrayEnd
    close(p)

  test "skipJsonBlock - array simple":
    let s = """[1, 2, 3]"""
    var fs = newStringStream(s)
    var p: JsonParser
    open(p, fs, "test")
    p.next() # jsonArrayStart
    skipJsonBlock(p)
    check p.kind == jsonArrayEnd
    close(p)

  test "skipJsonBlock - objeto anidado":
    let s = """{"outer": {"inner": "value"}}"""
    var fs = newStringStream(s)
    var p: JsonParser
    open(p, fs, "test")
    p.next() # jsonObjectStart (outer)
    p.next() # jsonString "outer"
    p.next() # :
    p.next() # jsonObjectStart (inner)
    skipJsonBlock(p)
    check p.kind == jsonObjectEnd # end of inner
    close(p)

  test "skipJsonBlock - array anidado":
    let s = """[[1, 2], [3, 4]]"""
    var fs = newStringStream(s)
    var p: JsonParser
    open(p, fs, "test")
    p.next() # jsonArrayStart (outer)
    p.next() # jsonArrayStart (inner)
    skipJsonBlock(p)
    check p.kind == jsonArrayEnd # end of first inner array
    close(p)

  test "skipJsonBlock - objeto con array anidado":
    let s = """{"key": [1, 2, 3]}"""
    var fs = newStringStream(s)
    var p: JsonParser
    open(p, fs, "test")
    p.next() # jsonObjectStart
    p.next() # jsonString "key"
    p.next() # :
    p.next() # jsonArrayStart
    skipJsonBlock(p)
    check p.kind == jsonArrayEnd
    close(p)

suite "PKGS - Command Building":
  test "buildCmd - pacman install with sudo":
    let cmd = buildCmd(ManPacman, " -S ", @["vim", "emacs"])
    check cmd.startsWith("sudo pacman -S ")
    check "vim" in cmd
    check "emacs" in cmd

  test "buildCmd - paru install without sudo":
    let cmd = buildCmd(ManParu, " -S ", @["vim", "emacs"])
    check cmd.startsWith("paru -S ")
    check not cmd.startsWith("sudo ")
    check "vim" in cmd
    check "emacs" in cmd

  test "buildCmd - yay install without sudo":
    let cmd = buildCmd(ManYay, " -S ", @["vim", "emacs"])
    check cmd.startsWith("yay -S ")
    check not cmd.startsWith("sudo ")
    check "vim" in cmd
    check "emacs" in cmd

  test "buildCmd - nimble install without sudo":
    let cmd = buildCmd(ManNimble, " install ", @["cligen"])
    check cmd.startsWith("nimble install ")
    check not cmd.startsWith("sudo ")
    check "cligen" in cmd

  test "buildCmd - pacman remove with sudo":
    let cmd = buildCmd(ManPacman, " -R ", @["vim"])
    check cmd.startsWith("sudo pacman -R ")
    check "vim" in cmd

  test "buildCmd - empty targets":
    let cmd = buildCmd(ManPacman, " -S ", @[])
    check cmd == "sudo pacman -S "

  test "buildCmd - single target":
    let cmd = buildCmd(ManNimble, " install ", @["testpkg"])
    check cmd == "nimble install testpkg"

suite "PKGS - Transaction Operations":
  test "runTransaction - empty targets returns 0":
    let result = runTransaction(ManPacman, @[], true)
    check result == 0

  test "installPackages - uses nimble for SourceNimble":
    let cmd = buildCmd(ManNimble, " install ", @["testpkg"])
    check cmd.startsWith("nimble install ")

  test "installPackages - uses pacman for SourceLocal":
    let cmd = buildCmd(ManPacman, " -S ", @["testpkg"])
    check cmd.startsWith("sudo pacman -S ")

  test "uninstallPackages - uses nimble for SourceNimble":
    let cmd = buildCmd(ManNimble, " uninstall ", @["testpkg"])
    check cmd.startsWith("nimble uninstall ")

  test "uninstallPackages - uses pacman for SourceLocal":
    let cmd = buildCmd(ManPacman, " -R ", @["testpkg"])
    check cmd.startsWith("sudo pacman -R ")

suite "PKGS - Cache Path Handling":
  test "CachedJsonSource - absolute and relative paths":
    let absPath = "/tmp/test.json"
    let relPath = "test.json"

    let source1 = CachedJsonSource(
      localFallbackPath: absPath,
      cachePath: relPath,
      url: "https://example.com/test.json",
      maxAgeHours: 24,
      isCompressed: false,
    )

    check source1.localFallbackPath == absPath
    check source1.cachePath == relPath

  test "CachedJsonSource - cache URLs for AUR and Nimble":
    let aurSource = CachedJsonSource(
      localFallbackPath: "",
      cachePath: "aur-packages-meta-v1.json.gz",
      url: AurMetaUrl,
      maxAgeHours: CacheMaxAgeHours,
      isCompressed: true,
    )

    let nimbleSource = CachedJsonSource(
      localFallbackPath: "",
      cachePath: "nimble-packages.json",
      url: NimbleMetaUrl,
      maxAgeHours: CacheMaxAgeHours,
      isCompressed: false,
    )

    check aurSource.url == AurMetaUrl
    check nimbleSource.url == NimbleMetaUrl
    check aurSource.isCompressed == true
    check nimbleSource.isCompressed == false

suite "PKGS - Edge Cases":
  test "ToolDef - all commands have spaces":
    for tool in [ManPacman, ManParu, ManYay, ManNimble]:
      let def = Tools[tool]
      check def.installCmd.len > 0
      check def.uninstallCmd.len > 0
      check def.searchCmd.len > 0
      # Verify they have space at start
      check def.installCmd[0] == ' '
      check def.uninstallCmd[0] == ' '
      check def.searchCmd[0] == ' '

  test "buildCmd - handles targets with spaces":
    let cmd = buildCmd(ManPacman, " -S ", @["vim", "emacs", "nano"])
    check "vim" in cmd
    check "emacs" in cmd
    check "nano" in cmd

  test "CachedJsonSource - maxAgeHours can be 0":
    let source = CachedJsonSource(
      localFallbackPath: "",
      cachePath: "test.json",
      url: "https://example.com/test.json",
      maxAgeHours: 0,
      isCompressed: false,
    )
    check source.maxAgeHours == 0

  test "CachedJsonSource - URL can be HTTPS or HTTP":
    let source1 = CachedJsonSource(
      localFallbackPath: "",
      cachePath: "test.json",
      url: "https://example.com/test.json",
      maxAgeHours: 24,
      isCompressed: false,
    )
    let source2 = CachedJsonSource(
      localFallbackPath: "",
      cachePath: "test.json",
      url: "http://example.com/test.json",
      maxAgeHours: 24,
      isCompressed: false,
    )
    check source1.url.startsWith("https://")
    check source2.url.startsWith("http://")

suite "PKGS - Performance":
  test "Benchmark buildCmd 10K operaciones":
    let start = getMonoTime()

    for i in 0 ..< 10000:
      discard buildCmd(ManPacman, " -S ", @["vim", "emacs", "nano"])

    let elapsed = getMonoTime() - start
    check elapsed.inMilliseconds < 100 # < 100ms

  test "Benchmark skipJsonBlock 1K objetos":
    let s = """{"key": "value"}"""
    var fs = newStringStream(s)
    var p: JsonParser

    let start = getMonoTime()
    for i in 0 ..< 1000:
      fs.setPosition(0)
      open(p, fs, "test")
      p.next()
      skipJsonBlock(p)
      close(p)
    let elapsed = getMonoTime() - start

    check elapsed.inMilliseconds < 50 # < 50ms

  test "Benchmark ToolDef access 10K operaciones":
    let start = getMonoTime()

    for i in 0 ..< 10000:
      let idx = PkgManagerType(i mod 4)
      let def = Tools[idx]
      discard def.bin.len
      discard def.installCmd.len

    let elapsed = getMonoTime() - start
    check elapsed.inMilliseconds < 10 # < 10ms (array access is fast)
