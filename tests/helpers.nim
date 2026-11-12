import std/os
import ../src/index/indexes
import ../src/index/source_index_builder

proc writeLe32*(data: var string, pos: int, value: uint32) =
  for i in 0 ..< 4:
    data[pos + i] = char((value shr (i * 8)) and 0xFF)

proc removeTree*(path: string) =
  if not dirExists(path):
    return
  for kind, child in walkDir(path):
    if kind == pcFile:
      removeFile(child)
    elif kind == pcDir:
      removeTree(child)
  removeDir(path)

proc makeNimbleFixture*(path: string): string =
  createDir(path)
  var builder = initSourceIndexBuilder(iskNimble)
  addPackageToIndex(
    builder,
    name = "nph",
    version = "git",
    repo = "nimble",
    installed = false,
    url = "https://github.com/example/nph",
    detail = "Repository     : nimble\nName           : nph\n",
  )
  result = path / "nimble.prix"
  discard finishSourceIndex(builder, result)
