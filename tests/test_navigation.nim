import std/unittest
import ../src/app/navigation
import ../src/catalog/[model, state]

suite "visible-list navigation":
  test "clamps the cursor and scrolls it into view":
    var state = newState(SlotSystem, false, {SlotSystem}, false)
    state.visibleIndices = @[0'i32, 1, 2, 3]
    state.cursor = 9

    updateNavigation(state, 3)

    check state.cursor == 3
    check state.scroll == 1

  test "scrolls up when the cursor moves above the viewport":
    var state = newState(SlotSystem, false, {SlotSystem}, false)
    state.visibleIndices = @[0'i32, 1, 2, 3, 4, 5]
    state.cursor = 2
    state.scroll = 4

    updateNavigation(state, 3)

    check state.cursor == 2
    check state.scroll == 2

  test "resets scroll for an empty result list":
    var state = newState(SlotSystem, false, {SlotSystem}, false)
    state.scroll = 4

    updateNavigation(state, 3)

    check state.scroll == 0
