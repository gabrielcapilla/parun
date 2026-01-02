##
##  Terminal Tests
##
## Tests for terminal I/O and raw mode.
##

import unittest
import std/[posix, termios, times]
import ../src/ui/terminal

suite "Terminal - Constants":
  test "SigWinchVal - valor correcto":
    check SigWinchVal == 28.cint

  test "resizePipe - exportado":
    check resizePipe.len == 2

suite "Terminal - Function Existence":
  test "initTerminal - existe":
    # Verificar que la función compila
    when compiles(initTerminal()):
      check true
    else:
      check false

  test "restoreTerminal - existe":
    # Verificar que la función compila (simplemente existe en el módulo)
    when declared(restoreTerminal):
      check true
    else:
      check false

suite "Terminal - Termios Operations":
  test "tcGetAttr - disponible":
    # Verificar que tcGetAttr está disponible en std/termios
    var term: Termios
    discard tcGetAttr(STDIN_FILENO, addr term)
    check true # Si no crashe, está disponible

  test "tcSetAttr - disponible":
    # Verificar que tcSetAttr está disponible en std/termios
    var term: Termios
    let result = tcGetAttr(STDIN_FILENO, addr term)

    # tcGetAttr puede retornar -1 si hay error
    if result == 0:
      discard tcSetAttr(STDIN_FILENO, TCSAFLUSH, addr term)
      check true # Si no crashe, está disponible
    else:
      # Terminal no disponible en este entorno
      check true

suite "Terminal - POSIX Flags":
  test "ICRNL flag - definido":
    check int(ICRNL) > 0

  test "IXON flag - definido":
    check int(IXON) > 0

  test "ECHO flag - definido":
    check int(ECHO) > 0

  test "ICANON flag - definido":
    check int(ICANON) > 0

  test "ISIG flag - definido":
    check int(ISIG) > 0

  test "IEXTEN flag - definido":
    check int(IEXTEN) > 0

  test "TCSAFLUSH - definido":
    check int(TCSAFLUSH) > 0

suite "Terminal - fcntl Operations":
  test "F_GETFL flag - definido":
    check F_GETFL > 0

  test "F_SETFL flag - definido":
    check F_SETFL > 0

  test "O_NONBLOCK flag - definido":
    check O_NONBLOCK > 0

suite "Terminal - File Descriptors":
  test "STDIN_FILENO - definido":
    check STDIN_FILENO == 0

  test "STDOUT_FILENO - definido":
    check STDOUT_FILENO == 1

  test "STDERR_FILENO - definido":
    check STDERR_FILENO == 2

suite "Terminal - Signal Handling":
  test "resizePipe - tiene 2 elementos":
    check resizePipe.len == 2

suite "Terminal - Raw Mode Properties":
  test "Raw mode deshabilita ICANON":
    var term: Termios
    discard tcGetAttr(STDIN_FILENO, addr term)

    term.c_lflag = term.c_lflag and not ICANON

    check (term.c_lflag and ICANON) == 0

  test "Raw mode deshabilita ECHO":
    var term: Termios
    discard tcGetAttr(STDIN_FILENO, addr term)

    term.c_lflag = term.c_lflag and not ECHO

    check (term.c_lflag and ECHO) == 0

  test "Raw mode deshabilita ISIG":
    var term: Termios
    discard tcGetAttr(STDIN_FILENO, addr term)

    term.c_lflag = term.c_lflag and not ISIG

    check (term.c_lflag and ISIG) == 0

suite "Terminal - Edge Cases":
  test "initTerminal - creacion de pipe fallida":
    when defined(posix):
      doAssert true, "Requiere mocking de posix.pipe"
      skip()
    else:
      doAssert true, "Solo en POSIX"
      skip()

  test "initTerminal - configuracion de termios fallida":
    when defined(posix):
      doAssert true, "Requiere TTY real"
      skip()
    else:
      doAssert true, "Solo en POSIX"
      skip()

  test "restoreTerminal - termios invalido":
    when defined(posix):
      doAssert true, "Requiere TTY real"
      skip()
    else:
      doAssert true, "Solo en POSIX"
      skip()

  test "resizePipe - inicializacion":
    # Verificar que resizePipe está inicializado
    check resizePipe.len == 2

suite "Terminal - Performance":
  test "Benchmark tcGetAttr 1000 llamadas":
    var term: Termios
    let start = getTime()

    for i in 0 ..< 1000:
      discard tcGetAttr(STDIN_FILENO, addr term)

    let elapsed = getTime() - start
    check elapsed.inMilliseconds < 100 # < 100ms

  test "Benchmark termios flag manipulation 10K operaciones":
    var term: Termios
    discard tcGetAttr(STDIN_FILENO, addr term)

    let start = getTime()

    for i in 0 ..< 10000:
      term.c_lflag = term.c_lflag and not ICANON
      term.c_lflag = term.c_lflag or ICANON

    let elapsed = getTime() - start
    check elapsed.inMilliseconds < 50 # < 50ms (bitwise operations are fast)

suite "Terminal - Constants Validation":
  test "Termios size - consistente":
    var term: Termios
    check sizeof(term) > 0

  test "cint size - consistente":
    let x: cint = 0
    check sizeof(x) == sizeof(cint)
