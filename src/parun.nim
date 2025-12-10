import std/[terminal, os, termios, selectors, tables, posix, strutils, sets]
import types, core, tui, pkgManager

proc initRawMode(): Termios =
  discard tcGetAttr(STDIN_FILENO, addr result)
  var raw = result
  raw.c_iflag = raw.c_iflag and not (ICRNL or IXON)
  raw.c_lflag = raw.c_lflag and not (ECHO or ICANON or ISIG or IEXTEN)
  discard tcSetAttr(STDIN_FILENO, TCSAFLUSH, addr raw)

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

  if b1 == 27:
    var pfd: TPollfd
    pfd.fd = STDIN_FILENO
    pfd.events = POLLIN
    if posix.poll(addr pfd, 1, 0) <= 0:
      return KeyEsc
    let b2 = readByte()
    let b3 = readByte()
    if b2 == ord('['):
      case b3
      of ord('A'):
        return KeyUp
      of ord('B'):
        return KeyDown
      of ord('C'):
        return KeyRight
      of ord('D'):
        return KeyLeft
      else:
        return '\0'
    elif b2 == ord('O'):
      case b3
      of ord('P'):
        return KeyF1
      else:
        return '\0'
    return '\0'
  return char(b1)

proc main() =
  let origTerm = initRawMode()
  stdout.write("\e[?1049h\e[?25l")
  stdout.flushFile()

  initPackageManager()
  var state = newState()
  requestLoadAll()

  let selector = newSelector[int]()
  selector.registerHandle(STDIN_FILENO, {Event.Read}, 0)

  defer:
    selector.close()
    shutdownPackageManager()
    stdout.write("\e[?1049l\e[?25h" & AnsiReset)
    discard tcSetAttr(STDIN_FILENO, TCSAFLUSH, addr origTerm)
    stdout.flushFile()

  while not state.shouldQuit:
    if state.shouldInstall or state.shouldUninstall:
      var targets: seq[string] = @[]

      if state.selected.len > 0:
        for s in state.selected:
          targets.add(s)
      elif state.visibleIndices.len > 0:
        let idx = state.visibleIndices[state.cursor]
        let p = state.pkgs[int(idx)]
        targets.add(state.getRepo(p) & "/" & state.getName(p))

      if targets.len > 0:
        stdout.write("\e[?1049l\e[?25h")
        discard tcSetAttr(STDIN_FILENO, TCSAFLUSH, addr origTerm)
        stdout.flushFile()

        let code =
          if state.shouldInstall:
            installPackages(targets)
          else:
            uninstallPackages(targets)

        quit(code)
      else:
        state.shouldInstall = false
        state.shouldUninstall = false

    if state.needsRedraw:
      let (frame, cx, cy) = renderUi(state, terminalHeight(), terminalWidth())
      setCursorPos(0, 0)
      stdout.write(frame)
      setCursorPos(cx, cy)
      stdout.flushFile()
      state.needsRedraw = false

      if state.showDetails and state.visibleIndices.len > 0:
        let idx = state.visibleIndices[state.cursor]
        let id = state.getPkgId(idx)
        if not state.detailsCache.hasKey(id):
          let p = state.pkgs[int(idx)]
          requestDetails(id, state.getName(p), state.getRepo(p))

    let ready = selector.select(20)
    if ready.len > 0:
      let k = readInputSafe()
      if k != '\0':
        state = update(state, Msg(kind: MsgInput, key: k), max(1, terminalHeight() - 1))

        if (k.ord >= 32 and k.ord <= 126) or k == KeyBack or k == KeyBackspace:
          if state.searchBuffer.len > 2:
            state.searchId.inc()
            requestSearch(state.searchBuffer, state.searchId)

    for msg in pollWorkerMessages():
      state = update(state, msg, max(1, terminalHeight() - 1))

if isMainModule:
  main()
