import std/[terminal, os, selectors, posix, strutils, parseopt, tables, bitops]
import types, core, tui, pkgManager, terminal as term, state, keyboard

proc main() =
  var
    startMode = ModeLocal
    startShowDetails = true
    startNimble = false

  var p = initOptParser()
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "noinfo", "n":
        startShowDetails = false
      of "nimble", "nim":
        startNimble = true
      else:
        discard
    else:
      discard

  var origTerm = initTerminal()
  initPackageManager()

  var appState = newState(startMode, startShowDetails, startNimble)

  if startNimble:
    requestLoadNimble(appState.searchId)
  else:
    requestLoadAll(appState.searchId)

  let selector = newSelector[int]()
  selector.registerHandle(STDIN_FILENO, {Event.Read}, 0)
  selector.registerHandle(resizePipe[0], {Event.Read}, 1)

  defer:
    selector.close()
    restoreTerminal(origTerm)
    shutdownPackageManager()

  var renderBuffer = newStringOfCap(64 * 1024)

  while not appState.shouldQuit:
    if appState.shouldInstall or appState.shouldUninstall:
      var targets: seq[string] = @[]
      let selCount = appState.getSelectedCount()
      let totalPkgs = appState.soa.locators.len

      if selCount > 0:
        for i, word in appState.selectionBits:
          if word == 0:
            continue
          for bit in 0 .. 63:
            if testBit(word, bit):
              let realIdx = i * 64 + bit
              if realIdx < totalPkgs:
                let s =
                  if appState.dataSource == SourceNimble:
                    appState.getName(realIdx)
                  else:
                    appState.getRepo(realIdx) & "/" & appState.getName(realIdx)

                if appState.shouldInstall:
                  if appState.dataSource == SourceNimble:
                    if s.contains('/'):
                      targets.add(s.split('/')[1])
                    else:
                      targets.add(s)
                  else:
                    targets.add(s)
                else:
                  if s.contains('/'):
                    targets.add(s.split('/')[1])
                  else:
                    targets.add(s)
      elif appState.visibleIndices.len > 0:
        let idx = int(appState.visibleIndices[appState.cursor])
        if appState.shouldInstall:
          if appState.dataSource == SourceNimble:
            targets.add(appState.getName(idx))
          else:
            targets.add(appState.getRepo(idx) & "/" & appState.getName(idx))
        else:
          targets.add(appState.getName(idx))

      if targets.len > 0:
        restoreTerminal(origTerm)
        let code =
          if appState.shouldInstall:
            installPackages(targets, appState.dataSource)
          else:
            uninstallPackages(targets, appState.dataSource)
        quit(code)
      else:
        appState.shouldInstall = false
        appState.shouldUninstall = false

    if appState.needsRedraw:
      let res = renderUi(appState, renderBuffer, terminalHeight(), terminalWidth())
      stdout.write("\e[?25l")
      setCursorPos(0, 0)
      stdout.write(renderBuffer)

      setCursorPos(res.cursorX, res.cursorY)
      stdout.write("\e[?25h")

      stdout.flushFile()
      appState.needsRedraw = false

      if appState.showDetails and appState.visibleIndices.len > 0:
        let idx = appState.visibleIndices[appState.cursor]
        if not appState.detailsCache.hasKey(idx):
          let i = int(idx)
          requestDetails(
            idx, appState.getName(i), appState.getRepo(i), appState.dataSource
          )

    let ready = selector.select(20)
    for key in ready:
      if key.fd == resizePipe[0]:
        var b: char
        discard posix.read(resizePipe[0], addr b, 1)
        appState.needsRedraw = true
      elif key.fd == STDIN_FILENO:
        let k = getKeyAsync()
        if k != '\0':
          let listH = max(1, terminalHeight() - 2)
          appState = update(appState, Msg(kind: MsgInput, key: k), listH)

          if appState.shouldQuit:
            break

          let isEditing =
            (k.ord >= 32 and k.ord <= 126) or k == KeyBack or k == KeyBackspace
          let isToggle = (k == KeyCtrlA)
          let shouldCheckNetwork = isEditing or isToggle

          if shouldCheckNetwork and not appState.viewingSelection:
            if appState.dataSource == SourceSystem:
              let hasAurPrefix = appState.searchBuffer.startsWith("aur/")
              let effectiveQuery = getEffectiveQuery(appState.searchBuffer)
              let active = hasAurPrefix
              if active and effectiveQuery.len > 2:
                appState.searchId.inc()
                requestSearch(effectiveQuery, appState.searchId)

    for msg in pollWorkerMessages():
      let listH = max(1, terminalHeight() - 2)
      appState = update(appState, msg, listH)

      if appState.shouldQuit:
        break

when isMainModule:
  main()
