import std/unittest

import ../src/app/update
import ../src/catalog/model
import ../src/catalog/state

suite "detail request generations":
  test "stale detail payloads cannot replace the active generation":
    var state = newState(SlotNimble, false, {SlotNimble}, true)
    let staleGeneration = state.detailGeneration + 1
    var stale = Msg(
      kind: MsgDetailsLoaded,
      pkgIdx: 0,
      pkgSlot: SlotNimble,
      detailGeneration: staleGeneration,
      quality: DetailManifest,
      content: "stale",
    )
    update(state, stale, 10)
    check not detailCacheHas(state.detailsCache, 0)

  test "stale detail errors cannot replace the active status":
    var state = newState(SlotNimble, false, {SlotNimble}, true)
    state.searchBuffer = "nimble/nph"
    state.statusMessage = ""
    var stale = Msg(
      kind: MsgError,
      errMsg: "stale error",
      errorDetailIdx: 0,
      errorDetailSlot: SlotNimble,
      errorDetailGeneration: state.detailGeneration + 1,
    )
    update(state, stale, 10)
    check state.searchBuffer == "nimble/nph"
    check state.statusMessage == ""

  test "matching detail generation is accepted":
    var state = newState(SlotNimble, false, {SlotNimble}, true)
    var current = Msg(
      kind: MsgDetailsLoaded,
      pkgIdx: 0,
      pkgSlot: SlotNimble,
      detailGeneration: state.detailGeneration,
      quality: DetailManifest,
      content: "current",
    )
    update(state, current, 10)
    check detailCacheGet(state.detailsCache, 0) == "current"
