import std/[strutils, tables]
import types, state

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

func handleStandard(state: var AppState, k: char, listHeight: int) =
  if state.inputMode == ModeVimInsert and k == KeyEsc:
    state.inputMode = ModeVimNormal
    return

  if k == KeyUp:
    if state.visibleIndices.len > 0:
      state.cursor = min(state.visibleIndices.len - 1, state.cursor + 1)
      state.detailScroll = 0
  elif k == KeyDown:
    if state.visibleIndices.len > 0:
      state.cursor = max(0, state.cursor - 1)
      state.detailScroll = 0
  elif k == KeyPageUp:
    if state.visibleIndices.len > 0:
      state.cursor = min(state.visibleIndices.len - 1, state.cursor + listHeight)
  elif k == KeyPageDown:
    if state.visibleIndices.len > 0:
      state.cursor = max(0, state.cursor - listHeight)
  elif k == KeyBack or k == KeyBackspace:
    if state.viewingSelection:
      state.viewingSelection = false
    if state.searchCursor > 0:
      state.searchBuffer.delete(state.searchCursor - 1 .. state.searchCursor - 1)
      state.searchCursor.dec()
      state.visibleIndices = filterIndices(state, state.searchBuffer)
      state.cursor = 0
  elif k == KeyLeft:
    if state.searchCursor > 0:
      state.searchCursor.dec()
  elif k == KeyRight:
    if state.searchCursor < state.searchBuffer.len:
      state.searchCursor.inc()
  elif k.ord >= 32 and k.ord <= 126:
    if state.viewingSelection:
      state.viewingSelection = false
    state.searchBuffer.insert($k, state.searchCursor)
    state.searchCursor.inc()
    state.visibleIndices = filterIndices(state, state.searchBuffer)
    state.cursor = 0
  elif k == KeyTab:
    toggleSelection(state)
  elif k == KeyEnter:
    state.shouldInstall = true
  elif k == KeyCtrlR:
    state.shouldUninstall = true
  elif k == KeyEsc:
    if state.viewingSelection:
      state.viewingSelection = false
      state.visibleIndices = filterIndices(state, state.searchBuffer)
    elif state.searchBuffer.len > 0:
      state.searchBuffer = ""
      state.searchCursor = 0
      state.visibleIndices = filterIndices(state, "")
    else:
      state.shouldQuit = true

proc handleInput*(state: var AppState, k: char, listHeight: int) =
  if state.inputMode == ModeVimCommand:
    handleVimCommand(state, k)
  elif state.inputMode == ModeVimNormal:
    handleVimNormal(state, k, listHeight)
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
