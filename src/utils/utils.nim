import std/[unicode, strutils]

func wrapText*(text: string, maxWidth: int): seq[string] {.noSideEffect.} =
  ## Wraps text to fit within maxWidth characters.
  ## Preserves existing newlines and handles word boundaries.
  result = @[]
  for line in text.splitLines():
    if line.len <= maxWidth:
      result.add(line)
      continue

    # Need to wrap this line
    var currentLine = ""
    var currentLen = 0
    var words = line.split(' ')

    for word in words:
      let wordWithSpace =
        if currentLen > 0:
          " " & word
        else:
          word
      let newLen = currentLen + wordWithSpace.len

      if newLen <= maxWidth:
        # Word fits on current line
        currentLine.add(wordWithSpace)
        currentLen = newLen
      elif word.len <= maxWidth:
        # Word doesn't fit but fits on new line
        if currentLine.len > 0:
          result.add(currentLine)
          currentLine = word
          currentLen = word.len
        else:
          # Single word too long, force wrap
          result.add(word[0 ..< maxWidth])
          if word.len > maxWidth:
            currentLine = word[maxWidth ..^ 1]
            currentLen = currentLine.len
          else:
            currentLine = ""
            currentLen = 0
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
