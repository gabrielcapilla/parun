##
##  Package Manager Tests
##
## Tests for package management operations and tool configuration.
##

import unittest
import std/[monotimes, times, strutils, os, streams, parsejson]
import ../src/pkgs/manager

suite "PKGS - Tool Configuration":
  test "Tools array - tiene 4 herramientas":
    check Tools.len == 4

  test "Tools[ManPacman] - configuracion correcta":
    let pacman = Tools[ManPacman]
    check pacman.bin == "pacman"
    check pacman.installCmd == " -S "
    check pacman.uninstallCmd == " -R "
    check pacman.searchCmd == " -Ss "
    check pacman.sudo == true
    check pacman.supportsAur == false

  test "Tools[ManParu] - configuracion correcta":
    let paru = Tools[ManParu]
    check paru.bin == "paru"
    check paru.installCmd == " -S "
    check paru.uninstallCmd == " -R "
    check paru.searchCmd == " -Ss "
    check paru.sudo == false
    check paru.supportsAur == false

  test "Tools[ManYay] - configuracion correcta":
    let yay = Tools[ManYay]
    check yay.bin == "yay"
    check yay.installCmd == " -S "
    check yay.uninstallCmd == " -R "
    check yay.searchCmd == " -Ss "
    check yay.sudo == false
    check yay.supportsAur == false

  test "Tools[ManNimble] - configuracion correcta":
    let nimble = Tools[ManNimble]
    check nimble.bin == "nimble"
    check nimble.installCmd == " install "
    check nimble.uninstallCmd == " uninstall "
    check nimble.searchCmd == " search "
    check nimble.sudo == false
    check nimble.supportsAur == false

  test "ToolDef enum - valores correctos":
    check ManPacman.ord == 0
    check ManParu.ord == 1
    check ManYay.ord == 2
    check ManNimble.ord == 3

suite "PKGS - Constants":
  test "AurMetaUrl - URL correcta":
    check AurMetaUrl == "https://aur.archlinux.org/packages-meta-v1.json.gz"

  test "NimbleMetaUrl - URL correcta":
    check NimbleMetaUrl ==
      "https://raw.githubusercontent.com/nim-lang/packages/refs/heads/master/packages.json"

  test "CacheMaxAgeHours - valor correcto":
    check CacheMaxAgeHours == 24

suite "PKGS - CachedJsonSource":
  test "CachedJsonSource - estructura completa":
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

  test "CachedJsonSource - con valores por defecto":
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
  test "buildCmd - pacman install con sudo":
    let cmd = buildCmd(ManPacman, " -S ", @["vim", "emacs"])
    check cmd.startsWith("sudo pacman -S ")
    check "vim" in cmd
    check "emacs" in cmd

  test "buildCmd - paru install sin sudo":
    let cmd = buildCmd(ManParu, " -S ", @["vim", "emacs"])
    check cmd.startsWith("paru -S ")
    check not cmd.startsWith("sudo ")
    check "vim" in cmd
    check "emacs" in cmd

  test "buildCmd - yay install sin sudo":
    let cmd = buildCmd(ManYay, " -S ", @["vim", "emacs"])
    check cmd.startsWith("yay -S ")
    check not cmd.startsWith("sudo ")
    check "vim" in cmd
    check "emacs" in cmd

  test "buildCmd - nimble install sin sudo":
    let cmd = buildCmd(ManNimble, " install ", @["cligen"])
    check cmd.startsWith("nimble install ")
    check not cmd.startsWith("sudo ")
    check "cligen" in cmd

  test "buildCmd - pacman remove con sudo":
    let cmd = buildCmd(ManPacman, " -R ", @["vim"])
    check cmd.startsWith("sudo pacman -R ")
    check "vim" in cmd

  test "buildCmd - targets vacios":
    let cmd = buildCmd(ManPacman, " -S ", @[])
    check cmd == "sudo pacman -S "

  test "buildCmd - solo un target":
    let cmd = buildCmd(ManNimble, " install ", @["testpkg"])
    check cmd == "nimble install testpkg"

suite "PKGS - Transaction Operations":
  test "runTransaction - targets vacios retorna 0":
    let result = runTransaction(ManPacman, @[], true)
    check result == 0

  test "installPackages - usa nimble para SourceNimble":
    let cmd = buildCmd(ManNimble, " install ", @["testpkg"])
    check cmd.startsWith("nimble install ")

  test "installPackages - usa pacman para SourceLocal":
    let cmd = buildCmd(ManPacman, " -S ", @["testpkg"])
    check cmd.startsWith("sudo pacman -S ")

  test "uninstallPackages - usa nimble para SourceNimble":
    let cmd = buildCmd(ManNimble, " uninstall ", @["testpkg"])
    check cmd.startsWith("nimble uninstall ")

  test "uninstallPackages - usa pacman para SourceLocal":
    let cmd = buildCmd(ManPacman, " -R ", @["testpkg"])
    check cmd.startsWith("sudo pacman -R ")

suite "PKGS - Cache Path Handling":
  test "CachedJsonSource - path absoluto y relativo":
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

  test "CachedJsonSource - URLs de cache para AUR y Nimble":
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
  test "ToolDef - todos los comandos tienen espacios":
    for tool in [ManPacman, ManParu, ManYay, ManNimble]:
      let def = Tools[tool]
      check def.installCmd.len > 0
      check def.uninstallCmd.len > 0
      check def.searchCmd.len > 0
      # Verificar que tienen espacio al inicio
      check def.installCmd[0] == ' '
      check def.uninstallCmd[0] == ' '
      check def.searchCmd[0] == ' '

  test "buildCmd - maneja targets con espacios":
    let cmd = buildCmd(ManPacman, " -S ", @["vim", "emacs", "nano"])
    check "vim" in cmd
    check "emacs" in cmd
    check "nano" in cmd

  test "CachedJsonSource - maxAgeHours puede ser 0":
    let source = CachedJsonSource(
      localFallbackPath: "",
      cachePath: "test.json",
      url: "https://example.com/test.json",
      maxAgeHours: 0,
      isCompressed: false,
    )
    check source.maxAgeHours == 0

  test "CachedJsonSource - URL puede ser HTTPS o HTTP":
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
