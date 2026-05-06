## Worker protocol and batch-building primitives.
##
## Notes:
## - `WorkerReq` is the cross-thread command envelope.
## - `BatchBuilder` accumulates compact SoA payloads before channel send.
import std/[tables, monotimes, times]
import ../core/types
import contracts

type
  WorkerReqKind* = enum
    ReqLoadAll
    ReqLoadNimble
    ReqLoadAur
    ReqSearch
    ReqDetails
    ReqDiagnostics
    ReqStop

  WorkerReq* = object
    query*, pkgName*, pkgRepo*, pkgUrl*: string
    searchId*: int
    pkgIdx*: int32
    source*: DataSource
    pkgSlot*: SourceSlot
    targetSource*: DataSource
    targetMode*: SearchMode
    kind*: WorkerReqKind

  PkgManagerType* = PluginId
  ToolDef* = PluginContract

  ## Temporary accumulator for SoA data
  BatchBuilder* = object
    soa*: PackageSOA
    textChunk*: string
    repos*: seq[string]
    repoMap*: Table[string, uint8]
    source*: DataSource
    mode*: SearchMode

  WorkerThreadArgs* = object
    reqChan*: ptr Channel[WorkerReq]
    resChan*: ptr Channel[Msg]
    toolType*: PkgManagerType

const
  ManPacman* = PluginPacman
  ManParu* = PluginParu
  ManYay* = PluginYay
  ManNimble* = PluginNimble

const BatchSize* = 64 * 1024

func getToolDef*(tool: PkgManagerType): lent ToolDef {.inline.} =
  ## Returns plugin contract used by worker/manager for this tool.
  getPluginContract(tool)

func initBatchBuilder*(source: DataSource, mode: SearchMode): BatchBuilder =
  ## Initializes reusable batch buffers with pre-sized capacities.
  result.source = source
  result.mode = mode
  result.soa.hot.locators = newSeqOfCap[uint32](5000)
  result.soa.hot.nameLens = newSeqOfCap[uint8](5000)
  result.soa.hot.flags = newSeqOfCap[uint8](5000)
  result.soa.cold.verLens = newSeqOfCap[uint8](5000)
  result.soa.cold.repoIndices = newSeqOfCap[uint8](5000)

  result.textChunk = newStringOfCap(BatchSize)
  result.repos = newSeqOfCap[string](16)
  result.repoMap = initTable[string, uint8](16)

proc flushBatch*(
    bb: var BatchBuilder,
    resChan: var Channel[Msg],
    searchId: int,
    startTime: MonoTime,
    force: bool = false,
) =
  ## Sends current batch as `MsgSearchResults` and resets builder buffers.
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
  ## Appends one package record into current batch if capacity permits.
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
