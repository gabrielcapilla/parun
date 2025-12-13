import std/[unicode]

func stripAnsi*(s: string): string =
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

func visibleWidth*(s: string): int =
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

func truncate*(s: string, w: int): string =
  if s.len <= w:
    return s
  let clean = stripAnsi(s)
  if clean.runeLen <= w:
    return clean
  return clean.runeSubStr(0, w)

func sanitizeShell*(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of 'a' .. 'z',
        'A' .. 'Z',
        '0' .. '9',
        '-',
        '_',
        '.',
        '/',
        '+',
        '=',
        '@',
        '%',
        ' ',
        ',',
        ':':
      result.add(c)
    else:
      result.add('_')
