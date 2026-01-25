import ../types

proc updateNavigation*(state: var AppState, listHeight: int) =
  if state.visibleIndices.len > 0:
    state.cursor = clamp(state.cursor, 0, state.visibleIndices.len - 1)
    if state.cursor < state.scroll:
      state.scroll = state.cursor
    elif state.cursor >= state.scroll + listHeight:
      state.scroll = state.cursor - listHeight + 1
  else:
    state.scroll = 0
