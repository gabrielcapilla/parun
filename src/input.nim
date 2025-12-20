import std/[strutils, tables, unicode]
import types, state

proc deleteCharLeft(state: var AppState) =
  if state.searchCursor > 0:
    state.searchBuffer.delete(state.searchCursor - 1 .. state.searchCursor - 1)
    state.searchCursor.dec()
    state.visibleIndices = filterIndices(state, state.searchBuffer)
    state.cursor = 0

proc deleteWordLeft(state: var AppState) =
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
    state.visibleIndices = filterIndices(state, state.searchBuffer)
    state.cursor = 0

proc deleteCharRight(state: var AppState) =
  if state.searchCursor < state.searchBuffer.len:
    state.searchBuffer.delete(state.searchCursor .. state.searchCursor)
    state.visibleIndices = filterIndices(state, state.searchBuffer)
    state.cursor = 0

proc insertChar(state: var AppState, c: char) =
  if state.viewingSelection:
    state.viewingSelection = false
  state.searchBuffer.insert($c, state.searchCursor)
  state.searchCursor.inc()
  state.visibleIndices = filterIndices(state, state.searchBuffer)
  state.cursor = 0

proc moveCursorWordLeft(state: var AppState) =
  if state.searchCursor > 0:
    while state.searchCursor > 0 and state.searchBuffer[state.searchCursor - 1] == ' ':
      state.searchCursor.dec()

    while state.searchCursor > 0 and state.searchBuffer[state.searchCursor - 1] != ' ':
      state.searchCursor.dec()

proc moveCursorWordRight(state: var AppState) =
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

func handleVimCommand(state: var AppState, k: char) =
  case k
  of KeyEnter:
    let cmd = state.commandBuffer.strip()
    if cmd == "q" or cmd == "q!":
      state.shouldQuit = true
    else:
      state.commandBuffer = ""
      state.inputMode = ModeVimNormal
  of KeyEsc:
    state.commandBuffer = ""
    state.inputMode = ModeVimNormal
  of KeyBack, KeyBackspace:
    if state.commandBuffer.len > 0:
      state.commandBuffer.setLen(state.commandBuffer.len - 1)
    else:
      state.inputMode = ModeVimNormal
  elif k.ord >= 32 and k.ord <= 126:
    state.commandBuffer.add(k)
  else:
    discard

func handleVimNormal(state: var AppState, k: char, listHeight: int) =
  case k
  of 'j', KeyDown:
    if state.visibleIndices.len > 0:
      state.cursor = max(0, state.cursor - 1)
      state.detailScroll = 0
  of 'k', KeyUp:
    if state.visibleIndices.len > 0:
      state.cursor = min(state.visibleIndices.len - 1, state.cursor + 1)
      state.detailScroll = 0
  of 'g', KeyHome:
    if state.visibleIndices.len > 0:
      state.cursor = state.visibleIndices.len - 1
      state.scroll = max(0, state.cursor - listHeight + 1)
      state.detailScroll = 0
  of 'G', KeyEnd:
    if state.visibleIndices.len > 0:
      state.cursor = 0
      state.scroll = 0
      state.detailScroll = 0
  of KeyCtrlU, KeyPageUp:
    if state.visibleIndices.len > 0:
      state.cursor = min(state.visibleIndices.len - 1, state.cursor + listHeight)
      state.detailScroll = 0
  of KeyCtrlD, KeyPageDown:
    if state.visibleIndices.len > 0:
      state.cursor = max(0, state.cursor - listHeight)
      state.detailScroll = 0
  of KeyCtrlY:
    state.detailScroll = max(0, state.detailScroll - 1)
  of KeyCtrlE:
    if state.visibleIndices.len > 0:
      let id = state.getPkgId(state.visibleIndices[state.cursor])
      if state.detailsCache.hasKey(id):
        let lines = state.detailsCache[id].countLines()
        if state.detailScroll < lines - 1:
          state.detailScroll.inc()
  of 'i':
    state.inputMode = ModeVimInsert
  of '/':
    state.searchBuffer = ""
    state.searchCursor = 0
    state.visibleIndices = filterIndices(state, "")
    state.inputMode = ModeVimInsert
  of ':':
    state.commandBuffer = ""
    state.inputMode = ModeVimCommand
  of KeySpace:
    toggleSelection(state)
  of 'x':
    state.shouldUninstall = true
  of KeyEnter:
    state.shouldInstall = true
  of KeyEsc:
    if state.searchBuffer.len > 0:
      state.searchBuffer = ""
      state.searchCursor = 0
      state.visibleIndices = filterIndices(state, "")
    elif state.viewingSelection:
      state.viewingSelection = false
      state.visibleIndices = filterIndices(state, "")
  else:
    discard

proc handleVimInsert(state: var AppState, k: char, listHeight: int) =
  case k
  of KeyEsc:
    state.inputMode = ModeVimNormal
  of KeyBack, KeyBackspace:
    if state.viewingSelection:
      state.viewingSelection = false
    deleteCharLeft(state)
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
    toggleSelection(state)
  of KeyEnter:
    state.shouldInstall = true
  of KeyCtrlR:
    state.shouldUninstall = true
  else:
    if k.ord >= 32 and k.ord <= 126:
      insertChar(state, k)

proc handleStandard(state: var AppState, k: char, listHeight: int) =
  case k
  of KeyUp:
    if state.visibleIndices.len > 0:
      state.cursor = min(state.visibleIndices.len - 1, state.cursor + 1)
      state.detailScroll = 0
  of KeyDown:
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
    toggleSelection(state)
  of KeyEnter:
    state.shouldInstall = true
  of KeyCtrlR:
    state.shouldUninstall = true
  else:
    if k.ord >= 32 and k.ord <= 126:
      insertChar(state, k)

proc handleInput*(state: var AppState, k: char, listHeight: int) =
  case state.inputMode
  of ModeVimCommand:
    handleVimCommand(state, k)
  of ModeVimNormal:
    handleVimNormal(state, k, listHeight)
  of ModeVimInsert:
    handleVimInsert(state, k, listHeight)
  else:
    handleStandard(state, k, listHeight)

  if state.visibleIndices.len > 0:
    state.cursor = clamp(state.cursor, 0, state.visibleIndices.len - 1)
    if state.cursor < state.scroll:
      state.scroll = state.cursor
    elif state.cursor >= state.scroll + listHeight:
      state.scroll = state.cursor - listHeight + 1
  else:
    state.scroll = 0
