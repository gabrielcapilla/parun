import std/[strutils, tables, parseutils]

func parseInstalledPackages*(output: string): Table[string, string] =
  result = initTable[string, string]()
  for line in output.splitLines:
    let parts = line.split(' ')
    if parts.len > 1:
      result[parts[0]] = parts[1]

func parseAvailablePackages*(output: string): seq[tuple[repo, name, version: string]] =
  result = @[]
  for line in output.splitLines:
    if line.len == 0:
      continue
    var i = 0
    var repo, name, ver: string
    i += line.parseUntil(repo, ' ', i)
    i += line.skipWhitespace(i)
    i += line.parseUntil(name, ' ', i)
    i += line.skipWhitespace(i)
    i += line.parseUntil(ver, ' ', i)
    if repo.len > 0 and name.len > 0:
      result.add((repo, name, ver))

func parsePackageInfo*(output: string): string =
  return output

func isPackageInstalled*(line: string): bool =
  return line.contains("[installed]") or line.contains("[instalado]")
