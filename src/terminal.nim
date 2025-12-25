import std/[posix, termios]
import types

const SigWinchVal = 28.cint

var resizePipe*: array[2, cint]

proc handleSigWinch(sig: cint) {.noconv.} =
  var b: char = 'R'
  discard posix.write(resizePipe[1], addr b, 1)

proc initTerminal*(): Termios =
  if posix.pipe(resizePipe) != 0:
    quit("Critical Error: Could not create pipe for signals.")

  var pFlags = fcntl(resizePipe[0], F_GETFL, 0)
  discard fcntl(resizePipe[0], F_SETFL, pFlags or O_NONBLOCK)
  pFlags = fcntl(resizePipe[1], F_GETFL, 0)
  discard fcntl(resizePipe[1], F_SETFL, pFlags or O_NONBLOCK)

  posix.signal(SigWinchVal, handleSigWinch)

  discard tcGetAttr(STDIN_FILENO, addr result)
  var raw = result
  raw.c_iflag = raw.c_iflag and not (ICRNL or IXON)
  raw.c_lflag = raw.c_lflag and not (ECHO or ICANON or ISIG or IEXTEN)
  discard tcSetAttr(STDIN_FILENO, TCSAFLUSH, addr raw)

  var flags = fcntl(STDIN_FILENO, F_GETFL, 0)
  discard fcntl(STDIN_FILENO, F_SETFL, flags or O_NONBLOCK)

  stdout.write("\e[?1049h\e[?25l")
  stdout.flushFile()

proc restoreTerminal*(origTerm: var Termios) =
  stdout.write("\e[?1049l\e[?25h" & AnsiReset)
  discard tcSetAttr(STDIN_FILENO, TCSAFLUSH, addr origTerm)

  var flags = fcntl(STDIN_FILENO, F_GETFL, 0)
  discard fcntl(STDIN_FILENO, F_SETFL, flags and not O_NONBLOCK)

  discard posix.close(resizePipe[0])
  discard posix.close(resizePipe[1])
  stdout.flushFile()

proc sleepMicros(us: int) =
  var req = Timespec(tv_sec: Time(0), tv_nsec: us * 1000)
  var rem: Timespec
  discard nanosleep(req, rem)

func readByte(): int =
  var b: char
  if posix.read(STDIN_FILENO, addr b, 1) == 1:
    return ord(b)
  return -1

proc readInputSafe*(): char =
  let b1 = readByte()
  if b1 == -1:
    return '\0'

  if b1 == 13:
    return KeyEnter
  if b1 == 10:
    return KeyCtrlJ
  if b1 == 127:
    return KeyBack
  if b1 == 8:
    return KeyBackspace
  if b1 == 9:
    return KeyTab
  if b1 == 18:
    return KeyCtrlR
  if b1 == 1:
    return KeyCtrlA
  if b1 == 19:
    return KeyCtrlS
  if b1 == 14:
    return KeyCtrlN
  if b1 == 21:
    return KeyCtrlU
  if b1 == 4:
    return KeyCtrlD
  if b1 == 25:
    return KeyCtrlY
  if b1 == 5:
    return KeyCtrlE

  if b1 == 27:
    var retries = 0
    var b2 = -1
    while retries < 10:
      b2 = readByte()
      if b2 != -1:
        break
      sleepMicros(1000)
      inc retries

    if b2 == -1:
      return KeyEsc

    if b2 == ord('['):
      let b3 = readByte()
      if b3 == -1:
        return '\0'
      case b3
      of ord('A'):
        return KeyUp
      of ord('B'):
        return KeyDown
      of ord('C'):
        return KeyRight
      of ord('D'):
        return KeyLeft
      of ord('H'):
        return KeyHome
      of ord('F'):
        return KeyEnd
      of ord('5'):
        let b4 = readByte()
        if b4 == ord('~'):
          return KeyPageUp
        return '\0'
      of ord('6'):
        let b4 = readByte()
        if b4 == ord('~'):
          return KeyPageDown
        return '\0'
      else:
        return '\0'
    elif b2 == ord('O'):
      let b3 = readByte()
      case b3
      of ord('P'):
        return KeyF1
      of ord('H'):
        return KeyHome
      of ord('F'):
        return KeyEnd
      else:
        return '\0'
    return KeyEsc
  return char(b1)
