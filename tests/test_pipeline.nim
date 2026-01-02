##
##  Integration Pipeline Tests
##
## Tests the flow of data from Worker (simulated) -> Engine -> State -> UI.
##

import unittest
import std/[monotimes, times, strutils]
import ../src/core/[types, state, engine]
import ../src/pkgs/batcher
import ../src/ui/tui

suite "Integration - Data Pipeline":
  test "Pipeline: Batcher -> Channel -> Engine -> State -> TUI":
    # 1. Setup State
    var state = newState(ModeLocal, false, false)

    # 2. Simulate Worker (Batcher)
    var bb = initBatchBuilder()
    addPackage(bb, "vim", "8.0.0", "extra", true)
    addPackage(bb, "emacs", "25.0", "extra", false)
    addPackage(bb, "nano", "4.0", "core", true)

    var chan: Channel[Msg]
    chan.open()

    # Flush to channel
    flushBatch(bb, chan, 1, getMonoTime())

    # 3. Simulate Engine Event Loop (Receive Msg)
    let (ok, msg) = chan.tryRecv()
    check ok == true
    check msg.kind == MsgSearchResults

    # Update State via Engine
    # Note: update returns a COPY of the state, so we must assign it
    state = update(state, msg, 20)

    # 4. Verify State
    check state.soa.hot.locators.len == 3
    check state.repos.len == 2 # extra, core
    # Engine updates visibleIndices automatically on new data if not viewing selection
    check state.visibleIndices.len == 3

    # 5. Verify TUI Render
    var buffer = ""
    let (cx, cy) = renderUi(state, buffer, 20, 80)

    check buffer.contains("vim")
    check buffer.contains("emacs")
    check buffer.contains("nano")
    check buffer.contains("extra")
    check buffer.contains("core")

    # Verify installed tag rendering (depends on renderer constants)
    # We know renderer uses "\e[36m[installed]\e[0m" or similar
    check buffer.contains("[installed]")

    chan.close()

  test "Pipeline: Input -> Filtering -> Render":
    # 1. Setup State with data
    var state = newState(ModeLocal, false, false)
    var bb = initBatchBuilder()
    addPackage(bb, "python", "3.9", "extra", true)
    addPackage(bb, "ruby", "2.7", "extra", false) # No 'p'

    var chan: Channel[Msg]
    chan.open()
    flushBatch(bb, chan, 1, getMonoTime())
    let (_, msg) = chan.tryRecv()
    state = update(state, msg, 20)
    chan.close()

    # Initial check
    check state.visibleIndices.len == 2

    # 2. User types "py"
    var inputMsg = Msg(kind: MsgInput, key: 'p')
    state = update(state, inputMsg, 20)

    inputMsg = Msg(kind: MsgInput, key: 'y')
    state = update(state, inputMsg, 20)

    check state.searchBuffer == "py"

    # 3. Verify Filtering
    # "python" matches "py" strongly
    # "ruby" does not match "p"

    check state.visibleIndices.len == 1
    let idx = state.visibleIndices[0]
    check state.getName(int(idx)) == "python"

    # 4. Verify Render
    var buffer = ""
    discard renderUi(state, buffer, 20, 80)

    check buffer.contains("python")
    check not buffer.contains("ruby")

  test "Pipeline: Selection Toggle":
    # 1. Setup State with data
    var state = newState(ModeLocal, false, false)
    var bb = initBatchBuilder()
    addPackage(bb, "pkg1", "1.0", "repo", false)
    addPackage(bb, "pkg2", "1.0", "repo", false)

    var chan: Channel[Msg]
    chan.open()
    flushBatch(bb, chan, 1, getMonoTime())
    let (_, msg) = chan.tryRecv()
    state = update(state, msg, 20)
    chan.close()

    # 2. Select first package (pkg1)
    # Cursor is at 0 by default
    var inputMsg = Msg(kind: MsgInput, key: char(9)) # Tab
    state = update(state, inputMsg, 20)

    check state.isSelected(0) == true
    check state.isSelected(1) == false

    # 3. View Selection Mode (Ctrl+S)
    inputMsg = Msg(kind: MsgInput, key: char(19)) # Ctrl+S
    state = update(state, inputMsg, 20)

    check state.viewingSelection == true
    check state.visibleIndices.len == 1
    check state.getName(int(state.visibleIndices[0])) == "pkg1"

    # 4. Render
    var buffer = ""
    discard renderUi(state, buffer, 20, 80)
    check buffer.contains("pkg1")
    check not buffer.contains("pkg2")
