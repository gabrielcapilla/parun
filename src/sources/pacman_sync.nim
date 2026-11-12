import std/[os, strutils, tables]

import pacman_query

{.passL: "-lzstd -lz".}

type
  ZstdCtx = pointer
  ZstdInBuf {.importc: "ZSTD_inBuffer", header: "<zstd.h>", bycopy.} = object
    src: pointer
    size: csize_t
    pos: csize_t

  ZstdOutBuf {.importc: "ZSTD_outBuffer", header: "<zstd.h>", bycopy.} = object
    dst: pointer
    size: csize_t
    pos: csize_t

proc ZSTD_createDCtx(): ZstdCtx {.importc, header: "<zstd.h>".}
proc ZSTD_freeDCtx(ctx: ZstdCtx): csize_t {.importc, header: "<zstd.h>".}
proc ZSTD_decompressStream(
  ctx: ZstdCtx, output: ptr ZstdOutBuf, input: ptr ZstdInBuf
): csize_t {.importc, header: "<zstd.h>".}

proc ZSTD_isError(code: csize_t): cuint {.importc, header: "<zstd.h>".}

type GzFile = pointer
proc gzopen(path: cstring, mode: cstring): GzFile {.importc, header: "<zlib.h>".}
proc gzread(f: GzFile, buf: pointer, len: cuint): cint {.importc, header: "<zlib.h>".}
proc gzclose(f: GzFile): cint {.importc, header: "<zlib.h>".}

const
  SyncDbDir* = "/var/lib/pacman/sync"
  TarBlockBytes = 512
  StreamWindowBytes = 65536
  MaxDescBytes = 1048576

proc validRepoName*(repo: string): bool =
  if repo.len == 0 or repo[0] == '.':
    return false
  for ch in repo:
    if ch notin {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '-', '.'}:
      return false
  true

proc parseOctal(value: openArray[char]): int =
  result = 0
  for ch in value:
    if ch == '\x00' or ch == ' ':
      continue
    if ch < '0' or ch > '7':
      return -1
    result = result * 8 + (ord(ch) - ord('0'))

proc memberDirName(member: string): string =
  var path = member
  if path.startsWith("./"):
    path = path[2 ..^ 1]
  let slash = path.find('/')
  if slash < 0:
    return ""
  path[0 ..< slash]

proc paddedDataBytes(size: int): int {.inline.} =
  size + ((TarBlockBytes - size mod TarBlockBytes) mod TarBlockBytes)

proc wantDesc(dirName, pkgName: string): bool =
  if dirName.len <= pkgName.len + 1:
    return false
  if not dirName.startsWith(pkgName):
    return false
  dirName[pkgName.len] == '-'

type TarScanState = enum
  tarHeader
  tarSkip
  tarCapture

type TarScan = object
  carry: string
  state: TarScanState
  skipRemaining: int
  captureRemaining: int
  captured: string
  finished: bool
  pkgName: string
  desc: string

proc feedScan(s: var TarScan, chunk: string) =
  if chunk.len == 0 or s.finished:
    return
  if s.carry.len == 0:
    s.carry = chunk
  else:
    s.carry.add(chunk)
  let buf = s.carry
  var pos = 0
  while true:
    if s.state == tarCapture:
      let take = min(s.captureRemaining, buf.len - pos)
      if take > 0:
        s.captured.add(buf[pos ..< pos + take])
        pos += take
        s.captureRemaining -= take
      if s.captureRemaining <= 0:
        if field(parseDescText(s.captured), "NAME") == s.pkgName:
          s.desc = move(s.captured)
          s.finished = true
        else:
          s.state = tarSkip
          s.skipRemaining =
            (TarBlockBytes - (s.captured.len mod TarBlockBytes)) mod TarBlockBytes
          s.captured = ""
        break
      if pos >= buf.len:
        break
      s.state = tarSkip
      s.skipRemaining =
        (TarBlockBytes - (s.captured.len mod TarBlockBytes)) mod TarBlockBytes
      continue
    if s.state == tarSkip:
      let take = min(s.skipRemaining, buf.len - pos)
      pos += take
      s.skipRemaining -= take
      if s.skipRemaining <= 0:
        s.state = tarHeader
      if pos >= buf.len:
        break
      continue
    if buf.len - pos < TarBlockBytes:
      break
    let kind = buf[pos + 156]
    let size = parseOctal(buf.toOpenArray(pos + 124, pos + 135))
    if size < 0:
      return
    var nameLen = 0
    while nameLen < 100 and buf[pos + nameLen] != '\x00':
      inc nameLen
    let member = buf[pos ..< pos + nameLen]
    pos += TarBlockBytes
    let dirName = memberDirName(member)
    let isDesc = member.endsWith("/desc")
    if kind == 'x' or kind == 'g' or kind notin {'\x00', '0'} or
        not (isDesc and wantDesc(dirName, s.pkgName)):
      s.state = tarSkip
      s.skipRemaining = paddedDataBytes(size)
      continue
    if size <= 0 or size > MaxDescBytes:
      return
    s.state = tarCapture
    s.captureRemaining = size
    s.captured = newStringOfCap(size)
    continue
  s.carry =
    if pos < buf.len:
      buf[pos ..^ 1]
    else:
      ""

proc streamGzipDb(dbPath: string, scan: var TarScan) =
  let gz = gzopen(dbPath.cstring, "rb")
  if gz == nil:
    return
  try:
    var window = newSeq[byte](StreamWindowBytes)
    while not scan.finished:
      let got = gzread(gz, addr window[0], StreamWindowBytes.cuint)
      if got <= 0:
        break
      var chunk = newString(int(got))
      copyMem(addr chunk[0], addr window[0], int(got))
      feedScan(scan, chunk)
  finally:
    discard gzclose(gz)

proc streamZstdDb(dbPath: string, scan: var TarScan) =
  var inputFile: File
  if not open(inputFile, dbPath):
    return
  let ctx = ZSTD_createDCtx()
  if ctx == nil:
    inputFile.close()
    return
  try:
    var inBlock = newSeq[byte](262144)
    var window = newSeq[byte](StreamWindowBytes)
    var input = ZstdInBuf(src: nil, size: 0, pos: 0)
    var inputEof = false
    while not scan.finished:
      if input.pos >= input.size and not inputEof:
        let got = inputFile.readBuffer(addr inBlock[0], inBlock.len)
        if got <= 0:
          inputEof = true
        else:
          input = ZstdInBuf(src: addr inBlock[0], size: got.csize_t, pos: 0)
      var output =
        ZstdOutBuf(dst: addr window[0], size: StreamWindowBytes.csize_t, pos: 0)
      let code = ZSTD_decompressStream(ctx, addr output, addr input)
      if ZSTD_isError(code) != 0:
        return
      if output.pos > 0:
        var chunk = newString(int(output.pos))
        copyMem(addr chunk[0], addr window[0], int(output.pos))
        feedScan(scan, chunk)
      if inputEof and (code == 0 or output.pos == 0):
        break
  finally:
    inputFile.close()
    discard ZSTD_freeDCtx(ctx)

proc scanSyncDb(repo, pkgName: string): string =
  if not validRepoName(repo) or pkgName.len == 0:
    return
  let dbPath = SyncDbDir / (repo & ".db")
  var scan = TarScan(pkgName: pkgName)
  var magic = newString(2)
  try:
    let probe = open(dbPath)
    if probe.readBuffer(addr magic[0], 2) != 2:
      probe.close()
      return
    probe.close()
  except CatchableError:
    return
  if magic == "\x1F\x8B":
    streamGzipDb(dbPath, scan)
  else:
    streamZstdDb(dbPath, scan)
  result = scan.desc

proc syncValidationLabels(sections: Table[string, seq[string]]): string =
  var labels: seq[string] = @[]
  if sections.hasKey("MD5SUM") and sections["MD5SUM"].len > 0:
    labels.add("MD5 Sum")
  if sections.hasKey("SHA256SUM") and sections["SHA256SUM"].len > 0:
    labels.add("SHA-256 Sum")
  if sections.hasKey("PGPSIG") and sections["PGPSIG"].len > 0:
    labels.add("Signature")
  if labels.len == 0:
    return "None"
  labels.join("  ")

proc formatSyncDetails*(repo, descText: string): string =
  let sections = parseDescText(descText)
  if field(sections, "NAME").len == 0:
    return ""
  var outRes = ""

  appendPacmanDetailRow(outRes, "Repository", repo)
  appendPacmanCommonFields(outRes, sections)
  if sections.hasKey("OPTDEPENDS") and sections["OPTDEPENDS"].len > 0:
    var optLines: seq[string] = @[]
    for entry in sections["OPTDEPENDS"]:
      optLines.add(entry)
    appendPacmanDetailRow(outRes, "Optional Deps", optLines[0])
    for extra in optLines[1 ..^ 1]:
      outRes.add(repeat(' ', 18))
      outRes.add(extra)
      outRes.add("\n")
  else:
    appendPacmanDetailRow(outRes, "Optional Deps", "None")
  for key in ["CONFLICTS", "REPLACES"]:
    let label = if key == "CONFLICTS": "Conflicts With" else: "Replaces"
    appendPacmanListField(outRes, sections, key, label)
  var csize: int64 = 0
  try:
    csize = parseInt(field(sections, "CSIZE")).int64
  except ValueError:
    discard
  let (dlValue, dlUnit) = humanizeParts(csize)
  const unitNames = ["B", "KiB", "MiB", "GiB", "TiB"]
  appendPacmanDetailRow(outRes, "Download Size", dlValue & " " & unitNames[dlUnit])
  var isize: int64 = 0
  try:
    isize = parseInt(field(sections, "ISIZE")).int64
  except ValueError:
    discard

  var isValue = isize.float
  for _ in 0 ..< dlUnit:
    isValue /= 1024.0
  appendPacmanDetailRow(
    outRes,
    "Installed Size",
    formatFloat(isValue, ffDecimal, 2) & " " & unitNames[dlUnit],
  )
  appendPacmanDetailRow(outRes, "Packager", field(sections, "PACKAGER"))
  var buildTs: int64 = 0
  try:
    buildTs = parseInt(field(sections, "BUILDDATE")).int64
  except ValueError:
    discard
  appendPacmanDetailRow(outRes, "Build Date", ctimeFormat(buildTs))
  appendPacmanDetailRow(outRes, "Validated By", syncValidationLabels(sections))
  outRes.add("\n")
  outRes

proc readSyncDesc*(repo, pkgName: string): string =
  scanSyncDb(repo, pkgName)
