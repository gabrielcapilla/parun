import std/[tables, monotimes, times]
import types

type BatchBuilder* = object
  soa*: PackageSOA
  textChunk*: string
  repos*: seq[string]
  repoMap*: Table[string, uint8]

func initBatchBuilder*(): BatchBuilder =
  result.soa.hot.locators = newSeqOfCap[uint32](1000)
  result.soa.hot.nameLens = newSeqOfCap[uint8](1000)
  result.soa.cold.verLens = newSeqOfCap[uint8](1000)
  result.soa.cold.repoIndices = newSeqOfCap[uint8](1000)
  result.soa.cold.flags = newSeqOfCap[uint8](1000)

  result.textChunk = newStringOfCap(BatchSize)
  result.repos = @[]
  result.repoMap = initTable[string, uint8]()

proc flushBatch*(
    bb: var BatchBuilder, resChan: var Channel[Msg], searchId: int, startTime: MonoTime
) =
  if bb.soa.hot.locators.len > 0:
    let dur = (getMonoTime() - startTime).inMilliseconds.int
    resChan.send(
      Msg(
        kind: MsgSearchResults,
        soa: bb.soa,
        textChunk: bb.textChunk,
        repos: bb.repos,
        searchId: searchId,
        isAppend: true,
        durationMs: dur,
      )
    )

    bb.soa.hot.locators.setLen(0)
    bb.soa.hot.nameLens.setLen(0)
    bb.soa.cold.verLens.setLen(0)
    bb.soa.cold.repoIndices.setLen(0)
    bb.soa.cold.flags.setLen(0)

    bb.textChunk.setLen(0)
    bb.repos.setLen(0)
    bb.repoMap.clear()

func addPackage*(bb: var BatchBuilder, name, ver, repo: string, installed: bool) =
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
      rIdx = 0

  let offset = uint32(bb.textChunk.len)
  bb.textChunk.add(name)
  bb.textChunk.add(ver)

  bb.soa.hot.locators.add(offset)
  bb.soa.hot.nameLens.add(uint8(name.len))
  bb.soa.cold.verLens.add(uint8(ver.len))
  bb.soa.cold.repoIndices.add(rIdx)
  bb.soa.cold.flags.add(if installed: 1 else: 0)
