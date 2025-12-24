import std/[tables, monotimes, times]
import types

type BatchBuilder* = object
  pkgs*: seq[PackedPackage]
  textBlock*: string
  repos*: seq[string]
  repoMap*: Table[string, uint8]

func initBatchBuilder*(): BatchBuilder =
  result.pkgs = newSeqOfCap[PackedPackage](1000)
  result.textBlock = newStringOfCap(BlockSize)
  result.repos = @[]
  result.repoMap = initTable[string, uint8]()

proc flushBatch*(
    bb: var BatchBuilder, resChan: var Channel[Msg], searchId: int, startTime: MonoTime
) =
  if bb.pkgs.len > 0:
    let dur = (getMonoTime() - startTime).inMilliseconds.int
    resChan.send(
      Msg(
        kind: MsgSearchResults,
        pkgs: bb.pkgs,
        textBlock: bb.textBlock,
        repos: bb.repos,
        searchId: searchId,
        isAppend: true,
        durationMs: dur,
      )
    )
    bb.pkgs.setLen(0)
    bb.textBlock.setLen(0)
    bb.repos.setLen(0)
    bb.repoMap.clear()

func addPackage*(bb: var BatchBuilder, name, ver, repo: string, installed: bool) =
  if bb.textBlock.len + name.len + ver.len > BlockSize:
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

  let offset = uint16(bb.textBlock.len)
  bb.textBlock.add(name)
  bb.textBlock.add(ver)

  bb.pkgs.add(
    PackedPackage(
      blockIdx: 0,
      offset: offset,
      repoIdx: rIdx,
      nameLen: uint8(name.len),
      verLen: uint8(ver.len),
      flags: if installed: 1 else: 0,
    )
  )
