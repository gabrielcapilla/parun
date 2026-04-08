import std/[unicode, strutils]

func wrapText*(text: string, maxWidth: int): seq[string] {.noSideEffect.} =
  ## Wraps text to fit within maxWidth characters.
  ## Preserves existing newlines and handles word boundaries.
  if maxWidth <= 0:
    return text.split('\n')
  result = newSeqOfCap[string](text.len div (maxWidth + 1) + 1)
  for line in text.split('\n'):
    if line.len <= maxWidth:
      result.add(line)
      continue

    # Need to wrap this line
    var currentLine = newStringOfCap(maxWidth)
    var currentLen = 0

    for word in line.split(' '):
      if word.len == 0:
        continue
      let separatorLen = (if currentLen > 0: 1 else: 0)
      let newLen = currentLen + separatorLen + word.len

      if newLen <= maxWidth:
        # Word fits on current line
        if separatorLen == 1:
          currentLine.add(' ')
        currentLine.add(word)
        currentLen = newLen
      elif word.len <= maxWidth:
        # Word doesn't fit but fits on new line
        if currentLine.len > 0:
          result.add(currentLine)
          currentLine = word
          currentLen = word.len
      else:
        # Word is longer than maxWidth, need to split it
        if currentLine.len > 0:
          result.add(currentLine)
          currentLine = ""
          currentLen = 0

        var wordIdx = 0
        while wordIdx < word.len:
          let remaining = word.len - wordIdx
          let take = min(remaining, maxWidth)
          result.add(word[wordIdx ..< wordIdx + take])
          wordIdx += take

    if currentLine.len > 0:
      result.add(currentLine)

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
      result += 1
      i += s.runeLenAt(i)

proc truncate*(s: string, maxW: int): string =
  var i = 0
  var w = 0
  result = newStringOfCap(s.len)
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
      let rl = s.runeLenAt(i)
      if w + 1 <= maxW:
        result.add(s[i ..< i + rl])
        w += 1
        i += rl
      else:
        break
