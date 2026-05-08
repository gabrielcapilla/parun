import std/unittest
import ../src/plugins/contracts
import ../src/plugins/manager

suite "transaction command construction":
  test "pacman install uses sudo argv without shell joining":
    let cmd = buildTransactionCommand(PluginPacman, " -S ", @["extra/git"])
    check cmd.exe == "sudo"
    check cmd.args == @["pacman", "-S", "extra/git"]

  test "nimble uninstall uses direct argv":
    let cmd = buildTransactionCommand(PluginNimble, " uninstall ", @["jester"])
    check cmd.exe == "nimble"
    check cmd.args == @["uninstall", "jester"]

  test "package validation rejects shell metacharacters":
    check isValidPackageName("extra/git")
    check isValidPackageName("nimble_pkg-1.2+dev")
    check not isValidPackageName("git;rm")
    check not isValidPackageName("extra/git && echo bad")
