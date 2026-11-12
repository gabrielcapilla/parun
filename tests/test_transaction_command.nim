import std/unittest
import ../src/sources/source_contracts
import ../src/sources/package_manager

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
    for invalid in [
      "", "/git", "extra/", "git;rm", "git|rm", "git&rm", "git$HOME", "git`id`",
      "git'quoted'", "git\"quoted\"", "git\nrm", "git\rrm", "git<file>", "git>file",
      "git(pkg)", "extra/git && echo bad", "..", "extra/..", "repo/pkg/other",
    ]:
      check not isValidPackageName(invalid)
