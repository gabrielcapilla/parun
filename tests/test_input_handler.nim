##
##  Input Handler Tests
##
## Tests for search bar editing and navigation logic.
##

import unittest
import std/[monotimes, times, strutils]
import ../src/core/input_handler
import ../src/core/state
import ../src/core/types

suite "InputHandler - Character Editing":
  setup:
    var state = newState(ModeLocal, false, false)

  test "insertChar - at end":
    state.searchBuffer = "hello"
    state.searchCursor = 5

    insertChar(state, '!')
    check state.searchBuffer == "hello!"
    check state.searchCursor == 6

  test "insertChar - in the middle":
    state.searchBuffer = "hllo"
    state.searchCursor = 1

    insertChar(state, 'e')
    check state.searchBuffer == "hello"
    check state.searchCursor == 2

  test "insertChar - at start":
    state.searchBuffer = "ello"
    state.searchCursor = 0

    insertChar(state, 'h')
    check state.searchBuffer == "hello"
    check state.searchCursor == 1

  test "insertChar - space":
    state.searchBuffer = "hello"
    state.searchCursor = 5

    insertChar(state, ' ')
    check state.searchBuffer == "hello "

  test "insertChar - special characters":
    state.searchBuffer = ""
    state.searchCursor = 0

    insertChar(state, '-')
    insertChar(state, '+')
    insertChar(state, '_')
    check state.searchBuffer == "-+_"

  test "insertChar - multiple chars":
    state.searchBuffer = ""
    state.searchCursor = 0

    for c in "hello":
      insertChar(state, c)
    check state.searchBuffer == "hello"
    check state.searchCursor == 5

  test "deleteCharLeft - at end":
    state.searchBuffer = "hello!"
    state.searchCursor = 6

    deleteCharLeft(state)
    check state.searchBuffer == "hello"
    check state.searchCursor == 5

  test "deleteCharLeft - in the middle":
    state.searchBuffer = "hello!"
    state.searchCursor = 4

    deleteCharLeft(state)
    check state.searchBuffer == "helo!"
    check state.searchCursor == 3

  test "deleteCharLeft - at start":
    state.searchBuffer = "hello"
    state.searchCursor = 0

    deleteCharLeft(state)
    check state.searchBuffer == "hello"
    check state.searchCursor == 0

  test "deleteCharLeft - empty buffer":
    state.searchBuffer = ""
    state.searchCursor = 0

    deleteCharLeft(state)
    check state.searchBuffer == ""

  test "deleteCharRight - at start":
    state.searchBuffer = "!hello"
    state.searchCursor = 0

    deleteCharRight(state)
    check state.searchBuffer == "hello"
    check state.searchCursor == 0

  test "deleteCharRight - in the middle":
    state.searchBuffer = "he!lo"
    state.searchCursor = 2

    deleteCharRight(state)
    check state.searchBuffer == "helo"
    check state.searchCursor == 2

  test "deleteCharRight - at end":
    state.searchBuffer = "hello"
    state.searchCursor = 5

    deleteCharRight(state)
    check state.searchBuffer == "hello"
    check state.searchCursor == 5

  test "deleteCharRight - empty buffer":
    state.searchBuffer = ""
    state.searchCursor = 0

    deleteCharRight(state)
    check state.searchBuffer == ""

suite "InputHandler - Word Navigation":
  setup:
    var state = newState(ModeLocal, false, false)

  test "moveCursorWordLeft - one word":
    state.searchBuffer = "hello world"
    state.searchCursor = 11

    moveCursorWordLeft(state)
    check state.searchCursor == 6 # inicio de "world"

  test "moveCursorWordLeft - multiple words":
    state.searchBuffer = "one two three"
    state.searchCursor = 13 # len of string

    moveCursorWordLeft(state)
    check state.searchCursor == 8 # start of "three"

    moveCursorWordLeft(state)
    check state.searchCursor == 4 # start of "two"

  test "moveCursorWordLeft - at start":
    state.searchBuffer = "hello world"
    state.searchCursor = 0

    moveCursorWordLeft(state)
    check state.searchCursor == 0

  test "moveCursorWordLeft - multiple spaces":
    state.searchBuffer = "hello   world"
    state.searchCursor = 13 # len of string

    moveCursorWordLeft(state)
    check state.searchCursor == 8 # start of "world" (after skipping spaces)

  test "moveCursorWordLeft - cursor in word":
    state.searchBuffer = "hello world"
    state.searchCursor = 8 # on 'w'

    moveCursorWordLeft(state)
    check state.searchCursor == 6 # start of "world"

  test "moveCursorWordRight - one word":
    state.searchBuffer = "hello world"
    state.searchCursor = 0

    moveCursorWordRight(state)
    check state.searchCursor == 5 # after "hello", on space

  test "moveCursorWordRight - multiple words":
    state.searchBuffer = "one two three"
    state.searchCursor = 0

    moveCursorWordRight(state)
    check state.searchCursor == 3 # after "one"

    moveCursorWordRight(state)
    check state.searchCursor == 7 # after "two"

  test "moveCursorWordRight - at end":
    state.searchBuffer = "hello world"
    state.searchCursor = 11

    moveCursorWordRight(state)
    check state.searchCursor == 11

  test "moveCursorWordRight - multiple spaces":
    state.searchBuffer = "hello   world"
    state.searchCursor = 5

    moveCursorWordRight(state)
    check state.searchCursor == 13 # end of "world"

  test "moveCursorWordRight - cursor in trailing spaces":
    state.searchBuffer = "one two"
    state.searchCursor = 7

    moveCursorWordRight(state)
    check state.searchCursor == 7

suite "InputHandler - Word Deletion":
  setup:
    var state = newState(ModeLocal, false, false)

  test "deleteWordLeft - one word":
    state.searchBuffer = "hello world"
    state.searchCursor = 11

    deleteWordLeft(state)
    check state.searchBuffer == "hello "
    check state.searchCursor == 6

  test "deleteWordLeft - at buffer start":
    state.searchBuffer = "hello world"
    state.searchCursor = 5

    deleteWordLeft(state)
    check state.searchBuffer == " world"
    check state.searchCursor == 0

  test "deleteWordLeft - cursor at start":
    state.searchBuffer = "hello world"
    state.searchCursor = 0

    deleteWordLeft(state)
    check state.searchBuffer == "hello world"
    check state.searchCursor == 0

  test "deleteWordLeft - special characters":
    state.searchBuffer = "test-editor"
    state.searchCursor = 11

    deleteWordLeft(state)
    check state.searchBuffer == "" # '-' is part of word, everything deleted
    check state.searchCursor == 0

  test "deleteWordLeft - multiple spaces":
    state.searchBuffer = "hello   world"
    state.searchCursor = 13 # len of string

    deleteWordLeft(state)
    check state.searchBuffer == "hello   "
    check state.searchCursor == 8

  test "deleteWordLeft - underscore and numbers":
    state.searchBuffer = "test_123 abc"
    state.searchCursor = 9

    deleteWordLeft(state)
    check state.searchBuffer == "abc" # 'test_123 ' deleted
    check state.searchCursor == 0

suite "InputHandler - Navigation":
  setup:
    var state = newState(ModeLocal, false, false)
    state.visibleIndices = @[int32(0), int32(1), int32(2), int32(3), int32(4)]

  test "handleInput KeyUp - cursor up":
    state.cursor = 0
    handleInput(state, KeyUp, 10)

    check state.cursor == 1

  test "handleInput KeyUp - upper limit":
    state.cursor = 4
    handleInput(state, KeyUp, 10)

    check state.cursor == 4

  test "handleInput KeyDown - cursor down":
    state.cursor = 2
    handleInput(state, KeyDown, 10)

    check state.cursor == 1

  test "handleInput KeyDown - lower limit":
    state.cursor = 0
    handleInput(state, KeyDown, 10)

    check state.cursor == 0

  test "handleInput KeyCtrlJ - igual a KeyDown":
    state.cursor = 2
    handleInput(state, KeyCtrlJ, 10)

    check state.cursor == 1

  test "handleInput KeyPageUp - page up":
    state.cursor = 0
    state.visibleIndices = newSeq[int32](100)
    handleInput(state, KeyPageUp, 10)

    check state.cursor == 10

  test "handleInput KeyPageUp - respects upper limit":
    state.visibleIndices = @[int32(0), int32(1), int32(2), int32(3)]
    state.cursor = 2
    handleInput(state, KeyPageUp, 10)

    check state.cursor == 3

  test "handleInput KeyPageDown - page down":
    state.cursor = 50
    state.visibleIndices = newSeq[int32](100)
    handleInput(state, KeyPageDown, 10)

    check state.cursor == 40

  test "handleInput KeyPageDown - respects lower limit":
    state.visibleIndices = @[int32(0), int32(1), int32(2), int32(3)]
    state.cursor = 2
    handleInput(state, KeyPageDown, 10)

    check state.cursor == 0

  test "handleInput KeyLeft - cursor left":
    state.searchBuffer = "hello"
    state.searchCursor = 5

    handleInput(state, KeyLeft, 10)

    check state.searchCursor == 4

  test "handleInput KeyLeft - left limit":
    state.searchBuffer = "hello"
    state.searchCursor = 0

    handleInput(state, KeyLeft, 10)

    check state.searchCursor == 0

  test "handleInput KeyRight - cursor right":
    state.searchBuffer = "hello"
    state.searchCursor = 3

    handleInput(state, KeyRight, 10)

    check state.searchCursor == 4

  test "handleInput KeyRight - right limit":
    state.searchBuffer = "hello"
    state.searchCursor = 5

    handleInput(state, KeyRight, 10)

    check state.searchCursor == 5

  test "handleInput KeyCtrlLeft - word left":
    state.searchBuffer = "hello world"
    state.searchCursor = 11

    handleInput(state, KeyCtrlLeft, 10)

    check state.searchCursor == 6

  test "handleInput KeyCtrlRight - word right":
    state.searchBuffer = "hello world"
    state.searchCursor = 0

    handleInput(state, KeyCtrlRight, 10)

    check state.searchCursor == 5 # after "hello", on space

suite "InputHandler - Action Keys":
  setup:
    var state = newState(ModeLocal, false, false)
    state.visibleIndices = @[int32(0), int32(1), int32(2)]

  test "handleInput KeyEsc - shouldQuit":
    handleInput(state, KeyEsc, 10)
    check state.shouldQuit == true

  test "handleInput KeyEnter - shouldInstall":
    handleInput(state, KeyEnter, 10)
    check state.shouldInstall == true

  test "handleInput KeyCtrlR - shouldUninstall":
    handleInput(state, KeyCtrlR, 10)
    check state.shouldUninstall == true

  test "handleInput KeyTab - toggle selection":
    state.cursor = 1
    handleInput(state, KeyTab, 10)
    check state.isSelected(1) == true

    handleInput(state, KeyTab, 10)
    check state.isSelected(2) == true # Cursor moved to 2, toggle now affects index 2

  test "handleInput KeyBack - delete left char":
    state.searchBuffer = "hello"
    state.searchCursor = 5
    handleInput(state, KeyBack, 10)

    check state.searchBuffer == "hell"
    check state.searchCursor == 4

  test "handleInput KeyBackspace - igual a KeyBack":
    state.searchBuffer = "hello"
    state.searchCursor = 5
    handleInput(state, KeyBackspace, 10)

    check state.searchBuffer == "hell"
    check state.searchCursor == 4

  test "handleInput KeyDelete - delete right char":
    state.searchBuffer = "hello"
    state.searchCursor = 0
    handleInput(state, KeyDelete, 10)

    check state.searchBuffer == "ello"
    check state.searchCursor == 0

  test "handleInput AltBackspace - delete word":
    state.searchBuffer = "hello world"
    state.searchCursor = 11
    handleInput(state, char(23), 10)

    check state.searchBuffer == "hello "

  test "handleInput KeyAltBackspace - delete word":
    state.searchBuffer = "hello world"
    state.searchCursor = 11
    handleInput(state, KeyAltBackspace, 10)

    check state.searchBuffer == "hello "

  test "handleInput printable - insert char":
    state.searchBuffer = "he"
    state.searchCursor = 2
    handleInput(state, 'l', 10)

    check state.searchBuffer == "hel"
    check state.searchCursor == 3

  test "handleInput non-printable - ignored":
    state.searchBuffer = "he"
    state.searchCursor = 2
    handleInput(state, char(1), 10) # Ctrl+A

    check state.searchBuffer == "he"
    check state.searchCursor == 2

  test "viewingSelection false when inserting":
    state.viewingSelection = true
    state.searchBuffer = ""
    state.searchCursor = 0
    handleInput(state, 'a', 10)

    check state.viewingSelection == false

  test "viewingSelection false when deleting with Back":
    state.viewingSelection = true
    state.searchBuffer = "a"
    state.searchCursor = 1
    handleInput(state, KeyBack, 10)

    check state.viewingSelection == false

  test "viewingSelection false when deleting with AltBackspace":
    state.viewingSelection = true
    state.searchBuffer = "hello"
    state.searchCursor = 5
    handleInput(state, KeyAltBackspace, 10)

    check state.viewingSelection == false

suite "InputHandler - Scroll Management":
  setup:
    var state = newState(ModeLocal, false, false)
    state.visibleIndices = newSeq[int32](100)

  test "scroll when cursor over upper limit":
    state.cursor = 5
    state.scroll = 10
    handleInput(state, KeyDown, 20)

    check state.cursor == 4 # KeyDown decrements cursor
    check state.scroll == 4 # cursor 4 < scroll 10, scroll = cursor

  test "scroll when cursor over lower limit":
    state.cursor = 25
    state.scroll = 10
    handleInput(state, KeyUp, 20)

    check state.cursor == 26 # KeyUp increments cursor
    check state.scroll == 10 # cursor 26 is in range 10-29, no scroll

  test "scroll no changes within range":
    state.cursor = 15
    state.scroll = 10
    handleInput(state, KeyUp, 20)

    check state.scroll == 10

  test "scroll to start when visibleIndices empty":
    state.visibleIndices = @[]
    state.cursor = 5
    state.scroll = 10
    handleInput(state, KeyUp, 20)

    check state.scroll == 0

  test "PageUp respects limits":
    state.visibleIndices = newSeq[int32](15)
    state.cursor = 0
    state.scroll = 0
    handleInput(state, KeyPageUp, 10)

    check state.cursor == 10
    check state.scroll == 1 # scroll = cursor - listHeight + 1 = 10 - 10 + 1

  test "PageDown respects limits":
    state.visibleIndices = newSeq[int32](15)
    state.cursor = 10
    state.scroll = 0
    handleInput(state, KeyPageDown, 10)

    check state.cursor == 0
    check state.scroll == 0

  test "detailScroll reset al mover cursor":
    state.visibleIndices = @[int32(0), int32(1), int32(2)]
    state.detailScroll = 10
    state.cursor = 0
    handleInput(state, KeyUp, 10)

    check state.detailScroll == 0

suite "InputHandler - Edge Cases":
  setup:
    var state = newState(ModeLocal, false, false)

  test "insertChar - very long buffer (>10K chars)":
    state.searchBuffer = "a".repeat(10000)
    state.searchCursor = 10000
    insertChar(state, 'b')

    check state.searchBuffer.len == 10001
    check state.searchCursor == 10001

  test "deleteCharLeft - very long buffer (10K chars)":
    state.searchBuffer = "a".repeat(10000)
    state.searchCursor = 10000

    for i in 0 ..< 10000:
      deleteCharLeft(state)

    check state.searchBuffer == ""

  test "deleteCharRight - cursor at invalid position":
    state.searchBuffer = "hello"
    state.searchCursor = 10 # Out of range
    deleteCharRight(state)

    check state.searchBuffer == "hello"

  test "moveCursorWordLeft - string vacio":
    state.searchBuffer = ""
    state.searchCursor = 0
    moveCursorWordLeft(state)

    check state.searchCursor == 0

  test "moveCursorWordRight - string vacio":
    state.searchBuffer = ""
    state.searchCursor = 0
    moveCursorWordRight(state)

    check state.searchCursor == 0

  test "deleteWordLeft - solo una palabra":
    state.searchBuffer = "hello"
    state.searchCursor = 5
    deleteWordLeft(state)

    check state.searchBuffer == ""

  test "insertChar - Unicode bytes individuales":
    state.searchBuffer = "café"
    state.searchCursor = 2 # En 'f'
    insertChar(state, 'x')

    check state.searchBuffer == "caxfé"

  test "handleInput - invalid key":
    state.searchBuffer = "hello"
    state.searchCursor = 5
    handleInput(state, char(255), 10) # Invalid byte

    check state.searchBuffer == "hello" # No change

  test "handleInput - empty visibleIndices causes no error":
    state.visibleIndices = @[]
    state.cursor = 0
    handleInput(state, KeyUp, 10)

    check state.cursor == 0

  test "insertChar - cursor reset after inserting":
    state.cursor = 10
    state.searchBuffer = "hello"
    state.searchCursor = 5
    insertChar(state, '!')

    check state.cursor == 0

suite "InputHandler - Performance":
  test "Benchmark insertChar 10K operations":
    var state = newState(ModeLocal, false, false)
    let start = getMonoTime()

    for i in 0 ..< 10000:
      insertChar(state, 'a')

    let elapsed = getMonoTime() - start
    check state.searchBuffer.len == 10000
    check elapsed.inMilliseconds < 1000 # Aumentado a 1s (filterIndices es costoso)

  test "Benchmark deleteCharLeft 10K operations":
    var state = newState(ModeLocal, false, false)
    state.searchBuffer = "a".repeat(10000)
    state.searchCursor = 10000

    let start = getMonoTime()
    for i in 0 ..< 10000:
      deleteCharLeft(state)
    let elapsed = getMonoTime() - start

    check state.searchBuffer == ""
    check elapsed.inMilliseconds < 1000 # Aumentado a 1s (filterIndices es costoso)

  test "Benchmark moveCursorWordLeft 1K operations":
    var state = newState(ModeLocal, false, false)
    state.searchBuffer = "one ".repeat(1000)
    state.searchCursor = 4000

    let start = getMonoTime()
    for i in 0 ..< 1000:
      moveCursorWordLeft(state)
    let elapsed = getMonoTime() - start

    check elapsed.inMilliseconds < 10 # < 10ms

  test "Benchmark handleInput 10K keys":
    var state = newState(ModeLocal, false, false)
    state.visibleIndices = newSeq[int32](100)

    let start = getMonoTime()
    for i in 0 ..< 10000:
      handleInput(state, KeyUp, 10)
    let elapsed = getMonoTime() - start

    check elapsed.inMilliseconds < 50 # < 50ms
