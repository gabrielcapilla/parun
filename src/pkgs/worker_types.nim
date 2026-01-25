import std/[tables, monotimes, times]
import ../core/types

type
  WorkerReqKind* = enum
    ReqLoadAll
    ReqLoadNimble
    ReqLoadAur
    ReqSearch
    ReqDetails
    ReqStop

  WorkerReq* = object
    kind*: WorkerReqKind
    query*, pkgName*, pkgRepo*: string
    pkgIdx*: int32
    searchId*: int
    source*: DataSource
    targetMode*: SearchMode
    targetSource*: DataSource

  PkgManagerType* = enum
    ManPacman
    ManParu
    ManYay
    ManNimble

  ToolDef* = object
    bin*: string
    installCmd*: string
    uninstallCmd*: string
    searchCmd*: string
    sudo*: bool
    supportsAur*: bool

  ## Temporary accumulator for SoA data
  BatchBuilder* = object
    soa*: PackageSOA
    textChunk*: string
    repos*: seq[string]
    repoMap*: Table[string, uint8]
    source*: DataSource
    mode*: SearchMode

const BatchSize* = 64 * 1024

func initBatchBuilder*(source: DataSource, mode: SearchMode): BatchBuilder =
  result.source = source
  result.mode = mode
  result.soa.hot.locators = newSeqOfCap[uint32](1000)
  result.soa.hot.nameLens = newSeqOfCap[uint8](1000)
  result.soa.hot.flags = newSeqOfCap[uint8](1000)
  result.soa.cold.verLens = newSeqOfCap[uint8](1000)
  result.soa.cold.repoIndices = newSeqOfCap[uint8](1000)

  result.textChunk = newStringOfCap(BatchSize)
  result.repos = @[]
  result.repoMap = initTable[string, uint8]()

proc flushBatch*(
    bb: var BatchBuilder,
    resChan: var Channel[Msg],
    searchId: int,
    startTime: MonoTime,
    force: bool = false,
) =
  if bb.soa.hot.locators.len > 0 or force:
    let dur = int((getMonoTime() - startTime).inMilliseconds())
    resChan.send(
      Msg(
        kind: MsgSearchResults,
        soa: bb.soa,
        textChunk: bb.textChunk,
        repos: bb.repos,
        searchId: searchId,
        isAppend: true,
        durationMs: dur,
        reqSource: bb.source,
        reqMode: bb.mode,
      )
    )

    # Efficient reset
    bb.soa.hot.locators.setLen(0)
    bb.soa.hot.nameLens.setLen(0)
    bb.soa.hot.flags.setLen(0)
    bb.soa.cold.verLens.setLen(0)
    bb.soa.cold.repoIndices.setLen(0)

    bb.textChunk.setLen(0)
    bb.repos.setLen(0)
    bb.repoMap.clear()

func addPackage*(
    bb: var BatchBuilder, name, ver: openArray[char], repo: string, installed: bool
) =
  if bb.textChunk.len + name.len + ver.len > BatchSize:
    return

  var rIdx: uint8 = 0
  if bb.repoMap.hasKey(repo):
    rIdx = bb.repoMap[repo]
  else:
    if bb.repos.len < 255:
      rIdx = uint8(bb.repos.len)
      bb.repos.add(repo)
      bb.repoMap[repo] = rIdx
    else:
      rIdx = 0 # Fallback

  let offset = uint32(bb.textChunk.len)
  for c in name:
    bb.textChunk.add(c)
  for c in ver:
    bb.textChunk.add(c)

  bb.soa.hot.locators.add(offset)
  bb.soa.hot.nameLens.add(uint8(name.len))
  bb.soa.hot.flags.add(if installed: 1'u8 else: 0'u8)
  bb.soa.cold.verLens.add(uint8(ver.len))
  bb.soa.cold.repoIndices.add(rIdx)
