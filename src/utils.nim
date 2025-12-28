## Helper functions for string manipulation with Unicode and ANSI support.

import std/unicode
import types

func stripAnsi*(s: string): string {.noSideEffect.} =
  ## Removes ANSI escape codes from a string.
  if s.len == 0:
    return ""
  result = newStringOfCap(s.len)
  var i = 0
  let L = s.len
  while i < L:
    let c = s[i]
    if c == '\e' and i + 1 < L and s[i + 1] == '[':
      inc(i, 2)
      while i < L and s[i] in {'0' .. '9', ';', '?', '!', '[', ']'}:
        inc(i)
      if i < L and s[i] in {'@' .. '~'}:
        inc(i)
    else:
      result.add(c)
      inc(i)

func visibleWidth*(s: string): int {.noSideEffect.} =
  ## Calculates the visual width of a string (ignoring ANSI and counting Unicode runes).
  var isAscii = true
  for c in s:
    if ord(c) >= 128 or c == '\e':
      isAscii = false
      break
  if isAscii:
    return s.len

  var i = 0
  let L = s.len
  var n = 0
  while i < L:
    let c = s[i]
    if c == '\e':
      inc(i)
      if i < L and s[i] == '[':
        inc(i)
        while i < L and s[i] notin {'@' .. '~'}:
          inc(i)
        if i < L:
          inc(i)
    elif ord(c) < 128:
      inc(n)
      inc(i)
    else:
      var r: Rune
      fastRuneAt(s, i, r, true)
      inc(n)
  return n

func truncate*(s: string, w: int): string {.noSideEffect.} =
  ## Truncates a string to a given visual width, respecting Unicode.
  if s.len <= w:
    return s
  let clean = stripAnsi(s)
  if clean.runeLen <= w:
    return clean
  return clean.runeSubStr(0, w)

func arenaToString*(
    arena: StringArena, handle: StringArenaHandle
): string {.noSideEffect.} =
  ## Converts an arena handle back to a Nim string (Allocates memory).
  result = newStringOfCap(handle.length)
  result.setLen(handle.length)
  copyMem(addr result[0], unsafeAddr arena.buffer[handle.startOffset], handle.length)
