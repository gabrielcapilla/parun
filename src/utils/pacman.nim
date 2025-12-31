## Pure functions to parse pacman command output.

import std/[strutils, tables]

func parseInstalledPackages*(output: string): Table[string, string] =
  ## Parses `pacman -Q` output into a hash table.
  result = initTable[string, string]()
  for line in output.splitLines:
    let parts = line.split(' ')
    if parts.len > 1:
      result[parts[0]] = parts[1]

func isPackageInstalled*(line: string): bool =
  ## Detects if a `pacman -Sl` line indicates the package is installed.
  return line.contains("[installed]") or line.contains("[instalado]")
