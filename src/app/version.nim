import std/[os, macros, strutils]

type NimbleSpec* = object
  path*: string
  content*: string
  version*: string

proc parseNimble*(path: string, content: string): NimbleSpec =
  result.path = path
  result.content = content
  for rawLine in content.splitLines():
    let line = rawLine.strip()
    if not line.startsWith("version"):
      continue
    for quote in ['"', '\'']:
      let parts = line.split(quote)
      if parts.len >= 2:
        result.version = parts[1].strip()
        return
  doAssert false, "no version field in: " & path

proc findNimbleFile*(dir: string): string =
  for kind, path in walkDir(dir):
    if path.endsWith(".nimble"):
      return path
  doAssert false, "no .nimble file in: " & dir

macro getVersion*(): untyped =
  let
    projectRoot = getProjectPath().parentDir()
    nimblePath = findNimbleFile(projectRoot)
    content = staticRead(nimblePath)
    spec = parseNimble(nimblePath, content)
  doAssert spec.version.len > 0, "no version in: " & nimblePath
  result = newStrLitNode(spec.version)
