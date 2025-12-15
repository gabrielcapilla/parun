import std/[terminal, os, selectors, posix, strutils, parseopt, sets, tables]
import types, core, tui, pkgManager, terminal as term, state

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

  var origTerm = initTerminal()
  initPackageManager()

  var appState = newState(startMode, startShowDetails, useVim, startNimble)

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
      if appState.selected.len > 0:
        for s in appState.selected:
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
        let idx = appState.visibleIndices[appState.cursor]
        let p = appState.pkgs[int(idx)]
        if appState.shouldInstall:
          if appState.dataSource == SourceNimble:
            targets.add(appState.getName(p))
          else:
            targets.add(appState.getRepo(p) & "/" & appState.getName(p))
        else:
          targets.add(appState.getName(p))

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

      if appState.inputMode == ModeVimCommand:
        setCursorPos(res.cursorX, res.cursorY)
        stdout.write("\e[?25h")
      elif appState.inputMode == ModeVimNormal:
        setCursorPos(terminalWidth(), terminalHeight())
      else:
        setCursorPos(res.cursorX, res.cursorY)
        stdout.write("\e[?25h")

      stdout.flushFile()
      appState.needsRedraw = false

      if appState.showDetails and appState.visibleIndices.len > 0:
        let idx = appState.visibleIndices[appState.cursor]
        let id = appState.getPkgId(idx)
        if not appState.detailsCache.hasKey(id):
          let p = appState.pkgs[int(idx)]
          requestDetails(
            id, appState.getName(p), appState.getRepo(p), appState.dataSource
          )

    let ready = selector.select(20)
    for key in ready:
      if key.fd == resizePipe[0]:
        var b: char
        discard posix.read(resizePipe[0], addr b, 1)
        appState.needsRedraw = true
      elif key.fd == STDIN_FILENO:
        let k = readInputSafe()
        if k != '\0':
          let listH = max(1, terminalHeight() - 2)
          appState = update(appState, Msg(kind: MsgInput, key: k), listH)

          let inInsert =
            appState.inputMode == ModeStandard or appState.inputMode == ModeVimInsert
          let isEditing =
            (k.ord >= 32 and k.ord <= 126) or k == KeyBack or k == KeyBackspace
          let isToggle = (k == KeyCtrlA)
          let shouldCheckNetwork = (isEditing and inInsert) or isToggle

          if shouldCheckNetwork and not appState.viewingSelection:
            if appState.dataSource == SourceSystem:
              let hasAurPrefix = appState.searchBuffer.startsWith("aur/")
              let effectiveQuery = getEffectiveQuery(appState.searchBuffer)
              let active = (appState.searchMode == ModeHybrid) or hasAurPrefix
              if active and effectiveQuery.len > 2:
                appState.searchId.inc()
                requestSearch(effectiveQuery, appState.searchId)

    for msg in pollWorkerMessages():
      let listH = max(1, terminalHeight() - 2)
      appState = update(appState, msg, listH)

when isMainModule:
  main()
