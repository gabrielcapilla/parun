## Shared text-formatting helpers for UI rendering.
import std/[unicode, strutils]

func addSlice(dst: var string, src: string, first, lastExcl: int) {.inline.} =
  for i in first ..< lastExcl:
    dst.add(src[i])

func wrapFieldLine*(line: string, maxWidth: int, dst: var seq[string]): bool {.noSideEffect.} =
  ## Wraps `Key            : value` records without collapsing label padding.
  let colon = line.find(':')
  if colon < 1 or colon > 24 or colon + 2 >= line.len:
    return false
  if line[colon + 1] != ' ':
    return false

  let prefixEnd = colon + 2
  if prefixEnd >= maxWidth:
    return false

  let firstPrefix = line[0 ..< prefixEnd]
  let restPrefix = spaces(prefixEnd)
  var currentLine = firstPrefix
  var currentLen = firstPrefix.len
  var baseLen = firstPrefix.len

  var wordStart = prefixEnd
  while wordStart < line.len:
    while wordStart < line.len and line[wordStart] == ' ':
      inc wordStart
    if wordStart >= line.len:
      break
    var wordEnd = wordStart
    while wordEnd < line.len and line[wordEnd] != ' ':
      inc wordEnd

    let wordLen = wordEnd - wordStart
    let separatorLen = (if currentLen > baseLen: 1 else: 0)
    let nextLen = currentLen + separatorLen + wordLen
    if nextLen <= maxWidth:
      if separatorLen == 1:
        currentLine.add(' ')
      currentLine.addSlice(line, wordStart, wordEnd)
      currentLen = nextLen
      wordStart = wordEnd
      continue

    if currentLen > baseLen:
      dst.add(currentLine)
      currentLine = restPrefix
      currentLen = restPrefix.len
      baseLen = restPrefix.len

    if currentLen + wordLen <= maxWidth:
      currentLine.addSlice(line, wordStart, wordEnd)
      currentLen += wordLen
    else:
      var wordIdx = wordStart
      while wordIdx < wordEnd:
        let room = maxWidth - currentLen
        if room == 0:
          dst.add(currentLine)
          currentLine = restPrefix
          currentLen = restPrefix.len
          baseLen = restPrefix.len
          continue
        let take = min(wordEnd - wordIdx, room)
        currentLine.addSlice(line, wordIdx, wordIdx + take)
        currentLen += take
        wordIdx += take
        if wordIdx < wordEnd:
          dst.add(currentLine)
          currentLine = restPrefix
          currentLen = restPrefix.len
          baseLen = restPrefix.len
    wordStart = wordEnd

  if currentLine.len > baseLen:
    dst.add(currentLine)
  else:
    dst.add(firstPrefix)
  true

func wrapText*(text: string, maxWidth: int): seq[string] {.noSideEffect.} =
  ## Wraps text to fit within maxWidth characters.
  ## Preserves existing newlines and handles word boundaries. Lines formatted as
  ## `Label           : value` keep their label/padding on the first row and use
  ## aligned continuation rows.
  if maxWidth <= 0:
    return text.split('\n')
  result = newSeqOfCap[string](text.len div (maxWidth + 1) + 1)
  for line in text.split('\n'):
    if line.len <= maxWidth:
      result.add(line)
      continue
    if wrapFieldLine(line, maxWidth, result):
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
  ## Computes printable width, skipping ANSI escape sequences.
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
  ## Truncates string to printable width while preserving ANSI sequences.
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
