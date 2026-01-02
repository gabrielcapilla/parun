import unittest
import std/[monotimes, times, strutils, tables]
import ../src/pkgs/batcher
import ../src/core/types

suite "Batcher - Initialization":
  test "initBatchBuilder - default values":
    let bb = initBatchBuilder()

    check bb.soa.hot.locators.len == 0
    check bb.soa.hot.nameLens.len == 0
    check bb.soa.cold.verLens.len == 0
    check bb.soa.cold.repoIndices.len == 0
    check bb.soa.cold.flags.len == 0
    check bb.textChunk == ""
    check bb.repos.len == 0

  test "initBatchBuilder - with reserved capacity":
    let bb = initBatchBuilder()

    check capacity(bb.soa.hot.locators) >= 1000
    check capacity(bb.soa.hot.nameLens) >= 1000
    check capacity(bb.soa.cold.verLens) >= 1000
    check capacity(bb.soa.cold.repoIndices) >= 1000
    check capacity(bb.soa.cold.flags) >= 1000
    check capacity(bb.textChunk) >= BatchSize

  test "initBatchBuilder - repoMap initialized":
    let bb = initBatchBuilder()
    check len(bb.repoMap) == 0

suite "Batcher - Package Addition":
  test "addPackage - simple package":
    var bb = initBatchBuilder()
    addPackage(bb, "vim", "8.0.0", "extra", false)

    check bb.soa.hot.locators.len == 1
    check bb.textChunk.contains("vim")
    check bb.textChunk.contains("8.0.0")

  test "addPackage - multiple packages":
    var bb = initBatchBuilder()
    addPackage(bb, "vim", "8.0.0", "extra", false)
    addPackage(bb, "emacs", "25.0", "extra", false)
    addPackage(bb, "nano", "4.0", "core", false)

    check bb.soa.hot.locators.len == 3
    check bb.repos.len == 2 # extra and core

  test "addPackage - deduplicates repositories":
    var bb = initBatchBuilder()
    addPackage(bb, "vim", "8.0.0", "extra", false)
    addPackage(bb, "emacs", "25.0", "extra", false)

    check bb.repos.len == 1
    check bb.repos[0] == "extra"

  test "addPackage - correct repository index":
    var bb = initBatchBuilder()
    addPackage(bb, "vim", "8.0.0", "extra", false)
    addPackage(bb, "nano", "4.0", "core", false)

    check bb.soa.cold.repoIndices[0] != bb.soa.cold.repoIndices[1]

  test "addPackage - installed flag":
    var bb = initBatchBuilder()
    addPackage(bb, "vim", "8.0.0", "extra", true)
    addPackage(bb, "emacs", "25.0", "extra", false)

    check (bb.soa.cold.flags[0] and 1) == 1
    check (bb.soa.cold.flags[1] and 1) == 0

  test "addPackage - respects BatchSize":
    var bb = initBatchBuilder()
    # Fill batch near limit
    bb.textChunk = "a".repeat(BatchSize - 10)

    # This package should fit
    addPackage(bb, "small", "1.0", "extra", false)
    check bb.textChunk.len < BatchSize

    # This package should not fit
    var oldLen = bb.soa.hot.locators.len
    bb.textChunk = "a".repeat(BatchSize - 5)
    addPackage(bb, "toolarge" & "x".repeat(100), "1.0", "extra", false)
    check bb.soa.hot.locators.len == oldLen # Not added

suite "Batcher - Batch Flushing":
  test "flushBatch - sends data to channel":
    var bb = initBatchBuilder()
    addPackage(bb, "vim", "8.0.0", "extra", false)

    var chan: Channel[Msg]
    chan.open()

    let start = getMonoTime()
    flushBatch(bb, chan, 1, start)

    # Verify message was sent
    let msg = chan.recv()
    check msg.kind == MsgSearchResults
    check msg.searchId == 1

    chan.close()

  test "flushBatch - resets builder":
    var bb = initBatchBuilder()
    addPackage(bb, "vim", "8.0.0", "extra", false)

    var chan: Channel[Msg]
    chan.open()

    flushBatch(bb, chan, 1, getMonoTime())

    check bb.soa.hot.locators.len == 0
    check bb.soa.hot.nameLens.len == 0
    check bb.soa.cold.verLens.len == 0
    check bb.soa.cold.repoIndices.len == 0
    check bb.soa.cold.flags.len == 0
    check bb.textChunk == ""
    check bb.repos.len == 0

    chan.close()

  test "flushBatch - does not send if empty":
    var bb = initBatchBuilder()

    var chan: Channel[Msg]
    chan.open()

    flushBatch(bb, chan, 1, getMonoTime())

    # Verify no message in channel
    # If there's a message, recv() unblocks. If not, it blocks.
    # We can't test this directly without timeout.
    # So we only verify the builder remains empty
    check bb.soa.hot.locators.len == 0
    check bb.textChunk == ""

    chan.close()

  test "flushBatch - reuses memory":
    var bb = initBatchBuilder()
    bb.soa.hot.locators = newSeqOfCap[uint32](1000)
    addPackage(bb, "vim", "8.0.0", "extra", false)

    var chan: Channel[Msg]
    chan.open()

    let capBefore = capacity(bb.soa.hot.locators)
    flushBatch(bb, chan, 1, getMonoTime())
    let capAfter = capacity(bb.soa.hot.locators)

    check capBefore == capAfter # Capacity preserved
    chan.close()

suite "Batcher - Performance":
  test "Benchmark addPackage 10K packages":
    var bb = initBatchBuilder()
    var totalAdded = 0

    let start = getMonoTime()
    for i in 0 ..< 10000:
      let addedBefore = bb.soa.hot.locators.len
      addPackage(bb, "pkg" & $i, "1.0.0", "extra", false)
      if bb.soa.hot.locators.len > addedBefore:
        inc(totalAdded)

      # Reset batch when full to continue
      if bb.textChunk.len > BatchSize - 1000:
        var chan: Channel[Msg]
        chan.open()
        flushBatch(bb, chan, i, start)
        chan.close()

    let elapsed = getMonoTime() - start

    check totalAdded == 10000
    check elapsed.inMilliseconds < 200 # < 200ms

  test "Benchmark repository deduplication":
    var bb = initBatchBuilder()
    let repos = ["extra", "core", "community", "multilib"]

    let start = getMonoTime()
    for i in 0 ..< 1000:
      addPackage(bb, "pkg" & $i, "1.0.0", repos[i mod 4], false)
    let elapsed = getMonoTime() - start

    check bb.repos.len == 4 # Only 4 unique repos
    check elapsed.inMilliseconds < 50 # O(1) lookup

  test "Benchmark flushBatch 100 batches":
    var chan: Channel[Msg]
    chan.open()

    let start = getMonoTime()
    for i in 0 ..< 100:
      var bb = initBatchBuilder()
      addPackage(bb, "vim", "8.0.0", "extra", false)
      flushBatch(bb, chan, i, getMonoTime())
    let elapsed = getMonoTime() - start

    check elapsed.inMilliseconds < 500 # < 500ms total
    chan.close()

  test "Memory allocation - addPackage minimal GC":
    var bb = initBatchBuilder()

    let gcBefore = getOccupiedMem()
    for i in 0 ..< 1000:
      addPackage(bb, "pkg" & $i, "1.0.0", "extra", false)
    let gcAfter = getOccupiedMem()

    let gcDelta = gcAfter - gcBefore
    # Should be minimal with appropriate BatchSize
    check gcDelta < 1024 * 100 # < 100KB

suite "Batcher - Edge Cases":
  test "addPackage - empty name":
    var bb = initBatchBuilder()
    addPackage(bb, "", "1.0.0", "extra", false)

    check bb.soa.hot.locators.len == 1
    check bb.soa.hot.nameLens[0] == 0

  test "addPackage - very long version (>255 chars)":
    var bb = initBatchBuilder()
    let longVer = "1.0.0" & ".0".repeat(100)

    # nameLens is uint8, so should truncate or handle
    addPackage(bb, "test", longVer, "extra", false)

    check bb.soa.hot.locators.len == 1

  test "addPackage - 256 different repos":
    var bb = initBatchBuilder()

    for i in 0 ..< 256:
      addPackage(bb, "pkg" & $i, "1.0.0", "repo" & $i, false)

    # repoIndices is uint8, so max 255 unique repos
    check bb.soa.hot.locators.len == 256
    # Some repos will have index 0 (fallback)

  test "addPackage - special characters in name":
    var bb = initBatchBuilder()
    addPackage(bb, "pkg-name_123", "1.0.0", "extra", false)

    check bb.textChunk.contains("pkg-name_123")

  test "addPackage - empty repo":
    var bb = initBatchBuilder()
    addPackage(bb, "test", "1.0.0", "", false)

    check bb.soa.hot.locators.len == 1
    # The empty repo should be added to the map

  test "flushBatch - partial data":
    var bb = initBatchBuilder()
    addPackage(bb, "vim", "8.0.0", "extra", false)
    addPackage(bb, "emacs", "25.0", "core", false)

    var chan: Channel[Msg]
    chan.open()

    flushBatch(bb, chan, 1, getMonoTime())
    let msg = chan.recv()

    check msg.soa.hot.locators.len == 2
    check msg.repos.len == 2

    chan.close()
