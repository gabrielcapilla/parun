import std/[strutils, tables]

func parseInstalledPackages*(output: string): Table[string, string] =
  result = initTable[string, string](512)
  for line in output.split('\n'):
    if line.len == 0: continue
    var first = ""
    var second = ""
    var i = 0
    for part in line.split(' '):
      if part.len == 0: continue
      if i == 0: first = part
      elif i == 1: second = part
      i.inc()
      if i > 1: break
    if first.len > 0:
      result[first] = second

func isPackageInstalled*(line: string): bool =
  return line.contains("[installed]") or line.contains("[instalado]")
