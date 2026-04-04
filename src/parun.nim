## Initializes the terminal, package manager, and main event loop.

import std/[posix, tables, terminal, selectors, strutils, parseopt, bitops, monotimes, times]
import ui/[tui, keyboard, terminal as term]
import core/[types, state, engine]
import pkgs/[indexes, manager]

const ParunVersion* = "0.5.3"

proc main() =
  var
    startMode = ModeLocal
    startShowDetails = true
    startNimble = false

  # CLI Argument Parsing
  var p = initOptParser()
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "version", "v":
        echo "parun version: ", ParunVersion
        quit(0)
      of "noinfo", "n":
        startShowDetails = false
      of "nimble", "nim":
        startNimble = true
      of "aur":
        startMode = ModeAUR
      else:
        stderr.writeLine("parun: unknown option -- '", key, "'")
        stderr.writeLine("Try 'parun --help' for more information.")
        quit(1)
    else:
      # Non-option arguments are not supported
      if kind == cmdArgument:
        stderr.writeLine("parun: unexpected argument '", key, "'")
        stderr.writeLine("Try 'parun --help' for more information.")
        quit(1)

  var origTerm = initTerminal()
  initPackageManager()

  var appState = newState(startMode, startShowDetails, startNimble)
  appState.prepareIndexedSources()

  # Async I/O Setup
  let selector = newSelector[int]()
  selector.registerHandle(STDIN_FILENO, {Event.Read}, 0)
  selector.registerHandle(resizePipe[0], {Event.Read}, 1)

  defer:
    selector.close()
    closeIndexedSources(appState)
    restoreTerminal(origTerm)
    shutdownPackageManager()

  var renderBuffer = newStringOfCap(64 * 1024)
  var transactionTargets = newSeqOfCap[string](16)
  var pendingMsgs = newSeqOfCap[Msg](16)

  # Main Loop
  while not appState.shouldQuit:
    let termH = terminalHeight()
    let termW = terminalWidth()
    let listH = max(1, termH - 2)

    # Install/Uninstall Management
    if appState.shouldInstall or appState.shouldUninstall:
      transactionTargets.setLen(0)
      let selCount = getSelectedCount(appState.selectionBits)
      let totalPkgs = currentPackageCount(appState)
      let view = appState.activeView

      if selCount > 0:
        for i, word in appState.selectionBits:
          if word == 0:
            continue
          for bit in 0 .. 63:
            if testBit(word, bit):
              let realIdx = i * 64 + bit
              if realIdx < totalPkgs:
                let name = copyName(view, realIdx)
                if appState.shouldInstall:
                  if appState.dataSource == SourceNimble:
                    transactionTargets.add(name)
                  else:
                    transactionTargets.add(copyRepo(view, realIdx) & "/" & name)
                else:
                  transactionTargets.add(name)
      elif appState.visibleIndices.len > 0:
        let idx = int(appState.visibleIndices[appState.cursor])
        let name = copyName(view, idx)
        if appState.shouldInstall:
          if appState.dataSource == SourceNimble:
            transactionTargets.add(name)
          else:
            transactionTargets.add(copyRepo(view, idx) & "/" & name)
        else:
          transactionTargets.add(name)

      if transactionTargets.len > 0:
        restoreTerminal(origTerm)
        let code =
          if appState.shouldInstall:
            installPackages(transactionTargets, appState.dataSource)
          else:
            uninstallPackages(transactionTargets, appState.dataSource)
        quit(code)
      else:
        appState.shouldInstall = false
        appState.shouldUninstall = false

    # Rendering
    if appState.needsRedraw:
      try:
        let res = renderUi(appState, renderBuffer, termH, termW)
        stdout.write("\e[?25l")
        setCursorPos(0, 0)
        stdout.write(renderBuffer)

        setCursorPos(res.cursorX, res.cursorY)
        stdout.write("\e[?25h")

        stdout.flushFile()
        appState.needsRedraw = false
      except IOError:
        # Ignore EAGAIN errors during rapid terminal resize
        # Terminal will redraw on next iteration
        discard

    # Request details only for the stable current selection.
    if appState.showDetails and appState.visibleIndices.len > 0:
      let view = appState.activeView
      let idx = appState.visibleIndices[appState.cursor]
      if not appState.detailsCache.hasKey(idx):
        if appState.pendingDetailIdx != idx or appState.pendingDetailSlot != appState.activeSlot:
          appState.pendingDetailIdx = idx
          appState.pendingDetailSlot = appState.activeSlot
          appState.detailTargetSince = getMonoTime()
          appState.detailRequestInFlight = false
        elif not appState.detailRequestInFlight and
            (getMonoTime() - appState.detailTargetSince).inMilliseconds() >=
            DetailsRequestDebounceMs and appState.pendingDetailIdx == idx:
          let i = int(idx)
          requestDetails(
            idx,
            copyName(view, i),
            copyRepo(view, i),
            appState.dataSource,
            appState.activeSlot,
          )
          appState.detailRequestInFlight = true
      else:
        appState.pendingDetailIdx = -1
        appState.detailRequestInFlight = false
    else:
      appState.pendingDetailIdx = -1
      appState.detailRequestInFlight = false

    # Event Waiting (Input or Resize)
    let ready = selector.select(16)
    for key in ready:
      if key.fd == resizePipe[0]:
        # Drain all pending resize events at once (coalescing)
        var b: char
        while posix.read(resizePipe[0], addr b, 1) > 0:
          discard
        appState.needsRedraw = true
      elif key.fd == STDIN_FILENO:
        let k = getKeyAsync()
        if k != '\0':
          var inputMsg = Msg(kind: MsgInput, key: k)
          update(appState, inputMsg, listH)

          if appState.shouldQuit:
            break

    # Worker message processing
    pollWorkerMessages(pendingMsgs)
    for i in 0 ..< pendingMsgs.len:
      update(appState, pendingMsgs[i], listH)

      if appState.shouldQuit:
        break

when isMainModule:
  main()
