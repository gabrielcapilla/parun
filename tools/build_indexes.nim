import std/[json, os, osproc, parseopt, strutils]
import ../src/pkgs/[index_builder, indexes]

type
  Options = object
    outputDir: string

proc firstLine(text: string): string =
  for line in text.splitLines():
    if line.len > 0:
      return line
  ""

proc parseOptions(): Options =
  result.outputDir = getCurrentDir() / "tools/output/indexes"
  var p = initOptParser()
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdLongOption:
      case p.key
      of "output-dir":
        result.outputDir = p.val
      else:
        raise newException(ValueError, "unknown option --" & p.key)
    else:
      raise newException(ValueError, "unexpected argument: " & p.key)

proc statsJson(stats: SourceIndexStats, validated: ValidatedSourceIndex): JsonNode =
  %*{
    "path": absolutePath(stats.path),
    "source": sourceTag(stats.source),
    "package_count": stats.packageCount,
    "repo_count": stats.repoCount,
    "file_size_bytes": stats.fileSize,
    "validated": validated.valid,
    "validation_error": validated.error
  }

proc main() =
  let opts = parseOptions()
  createDir(opts.outputDir)
  let stats = buildAllSourceIndexes(opts.outputDir)

  let payload = %*{
    "environment": {
      "cwd": getCurrentDir(),
      "nim_version": firstLine(execProcess("nim --version"))
    },
    "indexes": [
      statsJson(stats[0], validateSourceIndex(stats[0].path)),
      statsJson(stats[1], validateSourceIndex(stats[1].path)),
      statsJson(stats[2], validateSourceIndex(stats[2].path))
    ]
  }

  echo pretty(payload)

when isMainModule:
  main()
