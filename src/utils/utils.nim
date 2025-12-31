import std/unicode

proc visibleWidth*(s: string): int =
  var i = 0
  result = 0
  while i < s.len:
    if s[i] == '\e':
      inc i
      if i < s.len and s[i] == '[':
        inc i
        while i < s.len and s[i] != 'm':
          inc i
        inc i
    else:
      # Use _ for unused variables
      let _ = s.runeAt(i)
      result += 1
      i += s.runeLenAt(i)

proc truncate*(s: string, maxW: int): string =
  var i = 0
  var w = 0
  result = ""
  while i < s.len and w < maxW:
    if s[i] == '\e':
      let start = i
      inc i
      if i < s.len and s[i] == '[':
        inc i
        while i < s.len and s[i] != 'm':
          inc i
        inc i
      result.add(s[start ..< i])
    else:
      let _ = s.runeAt(i)
      let rl = s.runeLenAt(i)
      if w + 1 <= maxW:
        result.add(s[i ..< i + rl])
        w += 1
        i += rl
      else:
        break
