## Sets terminal to "raw" mode (no echo, no line buffering) and
## handles SIGWINCH signal for resizing.

import std/[posix, termios]
import types

const SigWinchVal = 28.cint

var resizePipe*: array[2, cint]

proc handleSigWinch(sig: cint) {.noconv.} =
  ## Safe signal handler. Writes a byte to the pipe to notify main loop.
  var b: char = 'R'
  discard posix.write(resizePipe[1], addr b, 1)

proc initTerminal*(): Termios =
  ## Puts terminal in raw mode and sets up signal pipe.
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

  # Alt buffer + Hide cursor
  stdout.write("\e[?1049h\e[?25l")
  stdout.flushFile()

proc restoreTerminal*(origTerm: var Termios) =
  ## Restores original terminal configuration.
  stdout.write("\e[?1049l\e[?25h" & AnsiReset)
  discard tcSetAttr(STDIN_FILENO, TCSAFLUSH, addr origTerm)

  var flags = fcntl(STDIN_FILENO, F_GETFL, 0)
  discard fcntl(STDIN_FILENO, F_SETFL, flags and not O_NONBLOCK)

  discard posix.close(resizePipe[0])
  discard posix.close(resizePipe[1])
  stdout.flushFile()
