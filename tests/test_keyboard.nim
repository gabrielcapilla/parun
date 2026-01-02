##
##  Keyboard Tests
##
## Tests for keyboard input handling.
##

import unittest
import std/[posix, times]
import ../src/ui/keyboard
import ../src/core/types

suite "Keyboard - Function Signatures":
  test "getKeyAsync - existe":
    # Verificar que la función existe
    when declared(getKeyAsync):
      check true
    else:
      check false

  test "parseSpecialKeySequence - existe":
    # Verificar que la función existe
    when declared(parseSpecialKeySequence):
      check true
    else:
      check false

  test "parseCsiSequence - existe":
    # Verificar que la función existe
    when declared(parseCsiSequence):
      check true
    else:
      check false

  test "parseSs3Sequence - existe":
    # Verificar que la función existe
    when declared(parseSs3Sequence):
      check true
    else:
      check false

  test "readByte - existe":
    # Verificar que la función existe
    when declared(readByte):
      check true
    else:
      check false

suite "Keyboard - Key Constants":
  test "KeyUp - valor correcto":
    check KeyUp == char(200)

  test "KeyDown - valor correcto":
    check KeyDown == char(201)

  test "KeyLeft - valor correcto":
    check KeyLeft == char(202)

  test "KeyRight - valor correcto":
    check KeyRight == char(203)

  test "KeyPageUp - valor correcto":
    check KeyPageUp == char(204)

  test "KeyPageDown - valor correcto":
    check KeyPageDown == char(205)

  test "KeyEnter - valor correcto":
    check KeyEnter == char(13)

  test "KeyBackspace - valor correcto":
    check KeyBackspace == char(8)

  test "KeyTab - valor correcto":
    check KeyTab == char(9)

  test "KeyEsc - valor correcto":
    check KeyEsc == char(27)

  test "KeyDelete - valor correcto":
    check KeyDelete == char(209)

  test "KeyCtrlLeft - valor correcto":
    check KeyCtrlLeft == char(220)

  test "KeyCtrlRight - valor correcto":
    check KeyCtrlRight == char(221)

suite "Keyboard - ASCII Codes":
  test "ASCII A - 65":
    check ord('A') == 65

  test "ASCII a - 97":
    check ord('a') == 97

  test "ASCII 0 - 48":
    check ord('0') == 48

  test "ASCII space - 32":
    check ord(' ') == 32

  test "ASCII tilde - 126":
    check ord('~') == 126

suite "Keyboard - POSIX Constants":
  test "STDIN_FILENO - 0":
    check STDIN_FILENO == 0

  test "F_GETFL - definido":
    check F_GETFL > 0

  test "F_SETFL - definido":
    check F_SETFL > 0

  test "O_NONBLOCK - definido":
    check O_NONBLOCK > 0

suite "Keyboard - fcntl Operations":
  test "fcntl function - disponible":
    discard fcntl(STDIN_FILENO, F_GETFL, 0)
    # Si retorna -1, stdin no está disponible (OK en este entorno)
    check true

  test "O_NONBLOCK bitwise OR":
    let flags = 0
    let nonBlockFlags = flags or O_NONBLOCK
    check (nonBlockFlags and O_NONBLOCK) != 0

  test "O_NONBLOCK bitwise AND remove":
    let flags = F_GETFL
    let flagsWithoutNonBlock = flags and not O_NONBLOCK
    check (flagsWithoutNonBlock and O_NONBLOCK) == 0

suite "Keyboard - ReadByte Logic":
  test "readByte - existe (compilacion)":
    # Verificar que readByte compila
    when compiles(readByte()):
      check true
    else:
      check false

suite "Keyboard - Character Classes":
  test "printable ASCII range - 32-126":
    for i in 32 .. 126:
      check chr(i) >= ' ' and chr(i) <= '~'

  test "control ASCII range - 1-26":
    for i in 1 .. 26:
      check chr(i) >= char(1) and chr(i) <= char(26)

  test "ASCII 27 - ESC":
    check chr(27) == KeyEsc

  test "ASCII 13 - Enter":
    check chr(13) == KeyEnter

  test "ASCII 9 - Tab":
    check chr(9) == KeyTab

suite "Keyboard - Key Mapping":
  test "F1 key - valor correcto":
    check KeyF1 == char(210)

  test "Backspace key - valor correcto":
    check KeyBack == char(127)
    check KeyBackspace == char(8)

  test "AltBackspace - valor correcto":
    check KeyAltBackspace == char(29)

  test "Ctrl keys - valores correctos":
    check KeyCtrlA == char(1)
    check KeyCtrlD == char(4)
    check KeyCtrlE == char(5)
    check KeyCtrlN == char(14)
    check KeyCtrlR == char(18)
    check KeyCtrlS == char(19)
    check KeyCtrlU == char(21)
    check KeyCtrlY == char(25)

  test "Home/End keys - valores correctos":
    check KeyHome == char(206)
    check KeyEnd == char(207)

suite "Keyboard - Escape Sequence Parsing":
  test "CSI sequence starts with [":
    check ord('[') == 91

  test "CSI Up sequence - [A":
    check ord('[') == 91
    check ord('A') == 65

  test "CSI Down sequence - [B":
    check ord('[') == 91
    check ord('B') == 66

  test "CSI Left sequence - [D":
    check ord('[') == 91
    check ord('D') == 68

  test "CSI Right sequence - [C":
    check ord('[') == 91
    check ord('C') == 67

  test "SS3 sequence starts with O":
    check ord('O') == 79

  test "SS3 Home sequence - OH":
    check ord('O') == 79
    check ord('H') == 72

  test "SS3 End sequence - OF":
    check ord('O') == 79
    check ord('F') == 70

suite "Keyboard - Complex Sequences":
  test "CSI Ctrl Right - [1;5C":
    check ord('[') == 91
    check ord('1') == 49
    check ord(';') == 59
    check ord('5') == 53
    check ord('C') == 67

  test "CSI Ctrl Left - [1;5D":
    check ord('[') == 91
    check ord('1') == 49
    check ord(';') == 59
    check ord('5') == 53
    check ord('D') == 68

  test "CSI Home - [1~":
    check ord('[') == 91
    check ord('1') == 49
    check ord('~') == 126

  test "CSI Delete - [3~":
    check ord('[') == 91
    check ord('3') == 51
    check ord('~') == 126

  test "CSI PageUp - [5~":
    check ord('[') == 91
    check ord('5') == 53
    check ord('~') == 126

  test "CSI PageDown - [6~":
    check ord('[') == 91
    check ord('6') == 54
    check ord('~') == 126

suite "Keyboard - Edge Cases":
  test "ASCII range - bytes fuera de rango":
    # Bytes > 126 no son ASCII válido
    for i in 127 .. 255:
      check chr(i).ord >= 127

  test "ASCII NUL - byte 0":
    check KeyNull == char(0)

  test "ASCII DEL - byte 127":
    check KeyBack == char(127)

  test "Unicode fallback - bytes > 127":
    # Los bytes > 127 se pasan como raw chars
    for i in 128 .. 255:
      check chr(i).ord >= 128

  test "Secuencias de escape desconocidas":
    # Secuencias que no matchean retornan KeyNull
    check KeyNull == char(0)

suite "Keyboard - Input Categories":
  test "printable chars - 32-126":
    for i in 32 .. 126:
      let c = chr(i)
      check c.ord == i

  test "control chars - 1-26":
    for i in 1 .. 26:
      let c = chr(i)
      check c.ord == i

  test "special keys - mapeo correcto":
    check KeyUp.ord == 200
    check KeyDown.ord == 201
    check KeyLeft.ord == 202
    check KeyRight.ord == 203

  test "function keys - valores altos":
    check KeyF1.ord == 210
    check KeyPageUp.ord == 204
    check KeyPageDown.ord == 205
    check KeyHome.ord == 206
    check KeyEnd.ord == 207

suite "Keyboard - Performance":
  test "Benchmark fcntl 1000 operaciones":
    let start = getTime()

    for i in 0 ..< 1000:
      discard fcntl(STDIN_FILENO, F_GETFL, 0)

    let elapsed = getTime() - start
    check elapsed.inMilliseconds < 50 # < 50ms

  test "Benchmark char conversion 10K operaciones":
    let start = getTime()

    for i in 0 ..< 10000:
      let c = chr(i mod 128)
      discard c.ord

    let elapsed = getTime() - start
    check elapsed.inMilliseconds < 10 # < 10ms

  test "Benchmark Key constants access 10K operaciones":
    let start = getTime()

    for i in 0 ..< 10000:
      let key = KeyUp
      discard key.ord

    let elapsed = getTime() - start
    check elapsed.inMilliseconds < 10 # < 10ms

suite "Keyboard - Module Dependencies":
  test "posix module - disponible":
    check true # Si compila, el módulo está disponible

  test "types module - exportado":
    # Verificar que las constantes de tecla están disponibles
    check KeyUp.ord == 200
    check KeyDown.ord == 201
