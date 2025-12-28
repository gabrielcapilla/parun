## Implements search bar editing logic (insertion, deletion, word navigation)
## and package list navigation.

import std/strutils
import types, state

func deleteCharLeft(state: var AppState) =
  ## Deletes the character to the left of the cursor.
  if state.searchCursor > 0:
    state.searchBuffer.delete(state.searchCursor - 1 .. state.searchCursor - 1)
    state.searchCursor.dec()
    filterIndices(state, state.searchBuffer, state.visibleIndices)
    state.cursor = 0

func deleteWordLeft(state: var AppState) =
  ## Deletes the whole word to the left (Ctrl+Backspace).
  if state.searchCursor == 0:
    return

  let originalCursor = state.searchCursor
  let buffer = state.searchBuffer

  var wordStart = originalCursor

  while wordStart > 0:
    dec(wordStart)
    if buffer[wordStart] in {' ', '\t'}:
      continue
    else:
      inc(wordStart)
      break

  while wordStart > 0:
    let c = buffer[wordStart - 1]
    if c in {
      'a' .. 'z',
      'A' .. 'Z',
      '0' .. '9',
      '_',
      '+',
      '-',
      '*',
      '/',
      '=',
      '<',
      '>',
      '!',
      '@',
      '#',
      '$',
      '%',
      '^',
      '&',
      '~',
      '`',
      '?',
      '.',
    }:
      dec(wordStart)
    else:
      break

  if wordStart < originalCursor:
    state.searchBuffer.delete(wordStart .. originalCursor - 1)
    state.searchCursor = wordStart
    filterIndices(state, state.searchBuffer, state.visibleIndices)
    state.cursor = 0

func deleteCharRight(state: var AppState) =
  ## Deletes the character to the right of the cursor (Del).
  if state.searchCursor < state.searchBuffer.len:
    state.searchBuffer.delete(state.searchCursor .. state.searchCursor)
    filterIndices(state, state.searchBuffer, state.visibleIndices)
    state.cursor = 0

func insertChar(state: var AppState, c: char) =
  ## Inserts a character at the current cursor position.
  if state.viewingSelection:
    state.viewingSelection = false
  state.searchBuffer.insert($c, state.searchCursor)
  state.searchCursor.inc()
  filterIndices(state, state.searchBuffer, state.visibleIndices)
  state.cursor = 0

func moveCursorWordLeft(state: var AppState) =
  ## Moves cursor to the beginning of the previous word.
  if state.searchCursor > 0:
    while state.searchCursor > 0 and state.searchBuffer[state.searchCursor - 1] == ' ':
      state.searchCursor.dec()

    while state.searchCursor > 0 and state.searchBuffer[state.searchCursor - 1] != ' ':
      state.searchCursor.dec()

func moveCursorWordRight(state: var AppState) =
  ## Moves cursor to the beginning of the next word.
  var foundWord = false

  while state.searchCursor < state.searchBuffer.len and
      state.searchBuffer[state.searchCursor] == ' ':
    state.searchCursor.inc()

  while state.searchCursor < state.searchBuffer.len and
      state.searchBuffer[state.searchCursor] != ' ':
    state.searchCursor.inc()
    foundWord = true

  if not foundWord and state.searchCursor > 0:
    while state.searchCursor > 0 and state.searchBuffer[state.searchCursor - 1] == ' ':
      state.searchCursor.dec()

func handleInput*(state: var AppState, k: char, listHeight: int) =
  ## Main keyboard event dispatcher.
  case k
  of KeyUp:
    if state.visibleIndices.len > 0:
      state.cursor = min(state.visibleIndices.len - 1, state.cursor + 1)
      state.detailScroll = 0
  of KeyDown, KeyCtrlJ:
    if state.visibleIndices.len > 0:
      state.cursor = max(0, state.cursor - 1)
      state.detailScroll = 0
  of KeyPageUp:
    if state.visibleIndices.len > 0:
      state.cursor = min(state.visibleIndices.len - 1, state.cursor + listHeight)
  of KeyPageDown:
    if state.visibleIndices.len > 0:
      state.cursor = max(0, state.cursor - listHeight)
  of KeyBack, KeyBackspace:
    if state.viewingSelection:
      state.viewingSelection = false
    deleteCharLeft(state)
  of KeyEsc:
    state.shouldQuit = true
  of char(23), KeyAltBackspace:
    if state.viewingSelection:
      state.viewingSelection = false
    deleteWordLeft(state)
  of KeyDelete:
    deleteCharRight(state)
  of KeyLeft:
    if state.searchCursor > 0:
      state.searchCursor.dec()
  of KeyRight:
    if state.searchCursor < state.searchBuffer.len:
      state.searchCursor.inc()
  of KeyCtrlLeft:
    moveCursorWordLeft(state)
  of KeyCtrlRight:
    moveCursorWordRight(state)
  of KeyTab:
    toggleSelectionAtCursor(state)
  of KeyEnter:
    state.shouldInstall = true
  of KeyCtrlR:
    state.shouldUninstall = true
  else:
    if k.ord >= 32 and k.ord <= 126:
      insertChar(state, k)

  # Scroll adjustment to keep cursor visible
  if state.visibleIndices.len > 0:
    state.cursor = clamp(state.cursor, 0, state.visibleIndices.len - 1)
    if state.cursor < state.scroll:
      state.scroll = state.cursor
    elif state.cursor >= state.scroll + listHeight:
      state.scroll = state.cursor - listHeight + 1
  else:
    state.scroll = 0
