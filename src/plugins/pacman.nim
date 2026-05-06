## Parsing helpers for pacman textual outputs.
import std/[strutils, tables]

func parseInstalledPackages*(output: string): Table[string, bool] =
  ## Builds a set-like table from `pacman -Q` output.
  result = initTable[string, bool](512)
  for line in output.split('\n'):
    if line.len == 0:
      continue
    var first = ""
    var i = 0
    for part in line.split(' '):
      if part.len == 0:
        continue
      if i == 0:
        first = part
      i.inc()
      if i > 0:
        break
    if first.len > 0:
      result[first] = true

func isPackageInstalled*(line: string): bool =
  ## Detects installed marker in repository listing output.
  return line.contains("[installed]") or line.contains("[instalado]")
