import std/[posix]
import types

func readByte(): int =
  var b: char
  if posix.read(STDIN_FILENO, addr b, 1) == 1:
    return ord(b)
  return -1

func parseCsiSequence(): char =
  let b3 = readByte()
  if b3 == -1:
    return KeyEsc

  case b3
  of ord('A'):
    return KeyUp
  of ord('B'):
    return KeyDown
  of ord('C'):
    let b4 = readByte()
    if b4 == ord(';'):
      let b5 = readByte()
      if b5 == ord('5'):
        let b6 = readByte()
        if b6 == ord('C'):
          return KeyCtrlRight

    return KeyRight
  of ord('D'):
    let b4 = readByte()
    if b4 == ord(';'):
      let b5 = readByte()
      if b5 == ord('5'):
        let b6 = readByte()
        if b6 == ord('D'):
          return KeyCtrlLeft

    return KeyLeft
  of ord('H'):
    return KeyHome
  of ord('F'):
    return KeyEnd
  of ord('1'):
    let b4 = readByte()
    if b4 == ord('~'):
      return KeyHome
    elif b4 == ord(';'):
      let b5 = readByte()
      if b5 == ord('5'):
        let b6 = readByte()
        if b6 == ord('D'):
          return KeyCtrlLeft
        elif b6 == ord('C'):
          return KeyCtrlRight
      else:
        return KeyNull
    else:
      return KeyNull
  of ord('2'):
    let b4 = readByte()
    if b4 == ord('~'):
      return char(208)
    else:
      return KeyNull
  of ord('3'):
    let b4 = readByte()
    if b4 == ord('~'):
      return KeyDelete
    else:
      return KeyNull
  of ord('5'):
    let b4 = readByte()
    if b4 == ord('~'):
      return KeyPageUp
    else:
      return KeyNull
  of ord('6'):
    let b4 = readByte()
    if b4 == ord('~'):
      return KeyPageDown
    else:
      return KeyNull
  of ord('P'):
    return char(210)
  of ord('Q'):
    return char(211)
  of ord('R'):
    return char(212)
  of ord('S'):
    return char(213)
  else:
    return KeyNull

func parseSs3Sequence(): char =
  let b3 = readByte()
  case b3
  of ord('P'):
    return char(210)
  of ord('Q'):
    return char(211)
  of ord('R'):
    return char(212)
  of ord('S'):
    return char(213)
  of ord('H'):
    return KeyHome
  of ord('F'):
    return KeyEnd
  else:
    return KeyNull

func parseSpecialKeySequence(): char =
  let b2 = readByte()
  if b2 == -1:
    return KeyEsc

  case b2
  of ord('['):
    return parseCsiSequence()
  of ord('O'):
    return parseSs3Sequence()
  else:
    if b2 == 127 or b2 == 8:
      return KeyAltBackspace
    else:
      return char(b2)

proc getKeyAsync*(): char =
  var flags = fcntl(STDIN_FILENO, F_GETFL, 0)
  let oldFlags = flags
  discard fcntl(STDIN_FILENO, F_SETFL, flags or O_NONBLOCK)

  let b1 = readByte()
  var keyValue: char

  if b1 == -1:
    keyValue = KeyNull
  elif b1 == 27:
    keyValue = parseSpecialKeySequence()
  elif b1 == 13:
    keyValue = KeyEnter
  elif b1 == 10:
    keyValue = KeyCtrlJ
  elif b1 == 127 or b1 == 8:
    keyValue = KeyBackspace
  elif b1 == 9:
    keyValue = KeyTab
  elif b1 >= 32 and b1 <= 126:
    keyValue = char(b1)
  elif b1 >= 1 and b1 <= 26:
    keyValue = char(b1)
  else:
    keyValue = char(b1)

  discard fcntl(STDIN_FILENO, F_SETFL, oldFlags)
  return keyValue

func convertToLegacyChar*(k: char): char =
  return k
