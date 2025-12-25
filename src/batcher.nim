import std/[tables, monotimes, times]
import types

type BatchBuilder* = object
  soa*: PackageSOA
  textChunk*: string
  repos*: seq[string]
  repoMap*: Table[string, uint8]

func initBatchBuilder*(): BatchBuilder =
  result.soa.locators = newSeqOfCap[uint32](1000)
  result.soa.nameLens = newSeqOfCap[uint8](1000)
  result.soa.verLens = newSeqOfCap[uint8](1000)
  result.soa.repoIndices = newSeqOfCap[uint8](1000)
  result.soa.flags = newSeqOfCap[uint8](1000)

  result.textChunk = newStringOfCap(BatchSize)
  result.repos = @[]
  result.repoMap = initTable[string, uint8]()

proc flushBatch*(
    bb: var BatchBuilder, resChan: var Channel[Msg], searchId: int, startTime: MonoTime
) =
  if bb.soa.locators.len > 0:
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

    bb.soa.locators.setLen(0)
    bb.soa.nameLens.setLen(0)
    bb.soa.verLens.setLen(0)
    bb.soa.repoIndices.setLen(0)
    bb.soa.flags.setLen(0)

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

  bb.soa.locators.add(offset)
  bb.soa.nameLens.add(uint8(name.len))
  bb.soa.verLens.add(uint8(ver.len))
  bb.soa.repoIndices.add(rIdx)
  bb.soa.flags.add(if installed: 1 else: 0)
