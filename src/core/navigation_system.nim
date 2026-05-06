import types, state

## Keeps cursor and scroll in a valid range after list-size changes.
proc updateNavigation*(state: var AppState, listHeight: int) =
  if state.visibleCount() > 0:
    state.cursor = clamp(state.cursor, 0, state.visibleCount() - 1)
    if state.cursor < state.scroll:
      state.scroll = state.cursor
    elif state.cursor >= state.scroll + listHeight:
      state.scroll = state.cursor - listHeight + 1
  else:
    state.scroll = 0
