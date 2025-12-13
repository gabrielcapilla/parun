import std/[terminal, os, termios, selectors, posix, strutils, sets, tables, parseopt]
import types, core, tui, pkgManager

const SigWinchVal = 28.cint

var resizePipe: array[2, cint]

proc handleSigWinch(sig: cint) {.noconv.} =
  var b: char = 'R'
  discard posix.write(resizePipe[1], addr b, 1)

proc initRawMode(): Termios =
  discard tcGetAttr(STDIN_FILENO, addr result)
  var raw = result
  raw.c_iflag = raw.c_iflag and not (ICRNL or IXON)
  raw.c_lflag = raw.c_lflag and not (ECHO or ICANON or ISIG or IEXTEN)
  discard tcSetAttr(STDIN_FILENO, TCSAFLUSH, addr raw)
  var flags = fcntl(STDIN_FILENO, F_GETFL, 0)
  discard fcntl(STDIN_FILENO, F_SETFL, flags or O_NONBLOCK)

proc restoreBlockingMode() =
  var flags = fcntl(STDIN_FILENO, F_GETFL, 0)
  discard fcntl(STDIN_FILENO, F_SETFL, flags and not O_NONBLOCK)

proc sleepMicros(us: int) =
  var req = Timespec(tv_sec: Time(0), tv_nsec: us * 1000)
  var rem: Timespec
  discard nanosleep(req, rem)

proc readByte(): int =
  var b: char
  if posix.read(STDIN_FILENO, addr b, 1) == 1:
    return ord(b)
  return -1

proc readInputSafe(): char =
  let b1 = readByte()
  if b1 == -1:
    return '\0'

  if b1 == 10 or b1 == 13:
    return KeyEnter
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

proc main() =
  var
    startMode = ModeLocal
    startShowDetails = true
    useVim = false
    startNimble = false

  var p = initOptParser()
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "aur", "a":
        startMode = ModeHybrid
      of "noinfo", "n":
        startShowDetails = false
      of "vim":
        useVim = true
      of "nimble":
        startNimble = true
      else:
        discard
    else:
      discard

  if posix.pipe(resizePipe) != 0:
    quit("Error crítico: No se pudo crear pipe para señales.")

  var pFlags = fcntl(resizePipe[0], F_GETFL, 0)
  discard fcntl(resizePipe[0], F_SETFL, pFlags or O_NONBLOCK)
  pFlags = fcntl(resizePipe[1], F_GETFL, 0)
  discard fcntl(resizePipe[1], F_SETFL, pFlags or O_NONBLOCK)

  posix.signal(SigWinchVal, handleSigWinch)

  let origTerm = initRawMode()
  stdout.write("\e[?1049h\e[?25l")
  stdout.flushFile()

  initPackageManager()

  var state = newState(startMode, startShowDetails, useVim, startNimble)

  if startNimble:
    requestLoadNimble(state.searchId)
  else:
    requestLoadAll(state.searchId)

  let selector = newSelector[int]()
  selector.registerHandle(STDIN_FILENO, {Event.Read}, 0)
  selector.registerHandle(resizePipe[0], {Event.Read}, 1)

  defer:
    selector.close()
    discard posix.close(resizePipe[0])
    discard posix.close(resizePipe[1])
    stdout.write("\e[?1049l\e[?25h" & AnsiReset)
    discard tcSetAttr(STDIN_FILENO, TCSAFLUSH, addr origTerm)
    restoreBlockingMode()
    stdout.flushFile()

  var renderBuffer = newStringOfCap(64 * 1024)

  while not state.shouldQuit:
    if state.shouldInstall or state.shouldUninstall:
      var targets: seq[string] = @[]
      if state.selected.len > 0:
        for s in state.selected:
          if state.shouldInstall:
            targets.add(s)
          else:
            if s.contains('/'):
              targets.add(s.split('/')[1])
            else:
              targets.add(s)
      elif state.visibleIndices.len > 0:
        let idx = state.visibleIndices[state.cursor]
        let p = state.pkgs[int(idx)]
        if state.shouldInstall:
          targets.add(state.getRepo(p) & "/" & state.getName(p))
        else:
          targets.add(state.getName(p))

      if targets.len > 0:
        stdout.write("\e[?1049l\e[?25h")
        stdout.flushFile()
        discard tcSetAttr(STDIN_FILENO, TCSAFLUSH, addr origTerm)
        restoreBlockingMode()

        let code =
          if state.shouldInstall:
            installPackages(targets, state.dataSource)
          else:
            uninstallPackages(targets, state.dataSource)
        quit(code)
      else:
        state.shouldInstall = false
        state.shouldUninstall = false

    if state.needsRedraw:
      let res = renderUi(state, renderBuffer, terminalHeight(), terminalWidth())
      stdout.write("\e[?25l")
      setCursorPos(0, 0)
      stdout.write(renderBuffer)

      if state.inputMode == ModeVimCommand:
        setCursorPos(res.cursorX, res.cursorY)
        stdout.write("\e[?25h")
      elif state.inputMode == ModeVimNormal:
        setCursorPos(terminalWidth(), terminalHeight())
      else:
        setCursorPos(res.cursorX, res.cursorY)
        stdout.write("\e[?25h")

      stdout.flushFile()
      state.needsRedraw = false

      if state.showDetails and state.visibleIndices.len > 0:
        let idx = state.visibleIndices[state.cursor]
        let id = state.getPkgId(idx)
        if not state.detailsCache.hasKey(id):
          let p = state.pkgs[int(idx)]
          requestDetails(id, state.getName(p), state.getRepo(p), state.dataSource)

    let ready = selector.select(20)
    for key in ready:
      if key.fd == resizePipe[0]:
        var b: char
        discard posix.read(resizePipe[0], addr b, 1)
        state.needsRedraw = true
      elif key.fd == STDIN_FILENO:
        let k = readInputSafe()
        if k != '\0':
          let listH = max(1, terminalHeight() - 2)
          state = update(state, Msg(kind: MsgInput, key: k), listH)

          let inInsert =
            state.inputMode == ModeStandard or state.inputMode == ModeVimInsert
          let isEditing =
            (k.ord >= 32 and k.ord <= 126) or k == KeyBack or k == KeyBackspace
          let isToggle = (k == KeyCtrlA)
          let shouldCheckNetwork = (isEditing and inInsert) or isToggle

          if shouldCheckNetwork and not state.viewingSelection:
            if state.dataSource == SourceSystem:
              let hasAurPrefix = state.searchBuffer.startsWith("aur/")
              let effectiveQuery = getEffectiveQuery(state.searchBuffer)
              let active = (state.searchMode == ModeHybrid) or hasAurPrefix
              if active and effectiveQuery.len > 2:
                state.searchId.inc()
                requestSearch(effectiveQuery, state.searchId)

    for msg in pollWorkerMessages():
      let listH = max(1, terminalHeight() - 2)
      state = update(state, msg, listH)

if isMainModule:
  main()
