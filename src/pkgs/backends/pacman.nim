import std/[strutils, tables]

func parseInstalledPackages*(output: string): Table[string, string] =
  result = initTable[string, string]()
  for line in output.splitLines:
    let parts = line.split(' ')
    if parts.len > 1:
      result[parts[0]] = parts[1]

func isPackageInstalled*(line: string): bool =
  return line.contains("[installed]") or line.contains("[instalado]")
