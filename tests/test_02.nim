import std/[unittest, os, strutils, strformat]

import ../src/[core, types, pkgManager]

proc getResidentMemoryKB(): int =
  try:
    let content = readFile("/proc/self/statm")
    let parts = content.split(' ')
    if parts.len > 1:
      let pages = parseInt(parts[1])
      return pages * 4
  except:
    return 0

proc generateDummyBatch(searchId: int): Msg =
  var pages = newSeq[string]()
  var pkgs = newSeq[CompactPackage]()

  for i in 0 ..< 50:
    var page = newStringOfCap(PageSize)
    for j in 0 ..< (PageSize div 16):
      page.add("pkg-dummy-data--")
    pages.add(page)

  for i in 0 ..< 10_000:
    pkgs.add(
      CompactPackage(
        pageIdx: uint16(i mod 50), pageOffset: 0, repoIdx: 0, nameLen: 10, flags: 0
      )
    )

  result = Msg(
    kind: MsgSearchResults,
    packedPkgs: pkgs,
    pages: pages,
    repos: @["dummy_repo"],
    searchId: searchId,
    isAppend: true,
    durationMs: 10,
  )

suite "Memory Leak Detection":
  test "RAM stability after 500 recharge cycles":
    initPackageManager()
    defer:
      shutdownPackageManager()

    echo "\n[MemTest] Starting memory stress test..."

    let h1 = "#"
    let h2 = "RSS (KB)"
    let h3 = "Delta (KB)"
    let h4 = "Status"
    echo fmt"{h1:<5} | {h2:<10} | {h3:<10} | {h4:<10}"
    echo repeat("-", 45)

    var state = newState(ModeLocal, true, false, false)

    GC_fullCollect()
    let initialMem = getResidentMemoryKB()
    var prevMem = initialMem
    var stableMem = 0

    const Cycles = 500

    for i in 1 .. Cycles:
      state = update(state, Msg(kind: MsgInput, key: KeyCtrlN), 20)

      let heavyMsg = generateDummyBatch(state.searchId)
      state = update(state, heavyMsg, 20)

      let _ = pollWorkerMessages()

      GC_fullCollect()
      sleep(50)

      let currMem = getResidentMemoryKB()
      let delta = currMem - prevMem

      let status =
        if delta > 1000:
          "WARN ^"
        elif delta < -1000:
          "FREE v"
        else:
          "STABLE ="
      echo fmt"{i:<5} | {currMem:<10} | {delta:<10} | {status}"

      if i == 5:
        stableMem = currMem

      prevMem = currMem

    echo repeat("-", 45)

    let finalMem = getResidentMemoryKB()
    let totalGrowth = finalMem - stableMem

    echo fmt"[Result] Initial: {initialMem} KB"
    echo fmt"[Result] Stable (Iter 5): {stableMem} KB"
    echo fmt"[Result] Final (Iter {Cycles}): {finalMem} KB"
    echo fmt"[Result] Growth after stabilization: {totalGrowth} KB"

    if totalGrowth > 6000:
      echo "[FAILURE] Significant memory leak detected."
      fail()
    else:
      echo "[SUCCESS] Memory is stable."
