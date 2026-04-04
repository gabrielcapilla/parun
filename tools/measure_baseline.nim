import std/[json, monotimes, os, osproc, parseopt, posix, strutils, times]
import ../src/utils/procfs_metrics

type
  WinSize {.importc: "struct winsize", header: "<termios.h>", bycopy.} = object
    ws_row, ws_col, ws_xpixel, ws_ypixel: cushort

  Options = object
    binary: string
    output: string
    startupTimeoutMs: int
    quietMs: int
    markerTimeoutMs: int
    pollIntervalMs: int
    maxIdleRssKb: int
    maxIdlePssKb: int
    maxIdlePrivateDirtyKb: int
    maxSwitchVisibleMs: int

  PtyChild = object
    pid: int
    master: cint

proc forkpty(
    amaster: ptr cint, name: cstring, termp: pointer, winp: ptr WinSize
): cint {.importc, header: "<pty.h>".}

proc firstLine(text: string): string =
  for line in text.splitLines():
    if line.len > 0:
      return line
  ""

proc parseOptions(): Options =
  result = Options(
    binary: getCurrentDir() / "parun",
    output: getCurrentDir() / "tools/output/baseline.json",
    startupTimeoutMs: 30000,
    quietMs: 800,
    markerTimeoutMs: 10000,
    pollIntervalMs: 10,
    maxIdleRssKb: 0,
    maxIdlePssKb: 0,
    maxIdlePrivateDirtyKb: 0,
    maxSwitchVisibleMs: 0,
  )

  var p = initOptParser()
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdLongOption:
      case p.key
      of "binary":
        result.binary = p.val
      of "output":
        result.output = p.val
      of "startup-timeout-ms":
        result.startupTimeoutMs = parseInt(p.val)
      of "quiet-ms":
        result.quietMs = parseInt(p.val)
      of "marker-timeout-ms":
        result.markerTimeoutMs = parseInt(p.val)
      of "poll-interval-ms":
        result.pollIntervalMs = parseInt(p.val)
      of "max-idle-rss-kb":
        result.maxIdleRssKb = parseInt(p.val)
      of "max-idle-pss-kb":
        result.maxIdlePssKb = parseInt(p.val)
      of "max-idle-private-dirty-kb":
        result.maxIdlePrivateDirtyKb = parseInt(p.val)
      of "max-switch-visible-ms":
        result.maxSwitchVisibleMs = parseInt(p.val)
      else:
        raise newException(ValueError, "unknown option --" & p.key)
    else:
      raise newException(ValueError, "unexpected argument: " & p.key)

proc appendBytes(dst: var string, src: ptr char, count: int) =
  let oldLen = dst.len
  dst.setLen(oldLen + count)
  copyMem(addr dst[oldLen], src, count)

proc setNonBlocking(fd: cint) =
  let flags = fcntl(fd, F_GETFL, 0)
  if flags >= 0:
    discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

proc readAvailable(child: PtyChild, buffer: var string) =
  var chunk: array[4096, char]
  while true:
    let readCount = posix.read(child.master, addr chunk[0], chunk.len)
    if readCount > 0:
      appendBytes(buffer, addr chunk[0], readCount)
    elif readCount == 0:
      break
    else:
      let err = osLastError()
      if err.int == EAGAIN or err.int == EWOULDBLOCK:
        break
      raiseOSError(err)

proc writeAll(fd: cint, data: string) =
  var offset = 0
  while offset < data.len:
    let written = posix.write(fd, unsafeAddr data[offset], data.len - offset)
    if written <= 0:
      raiseOSError(osLastError())
    offset += written

proc childRunning(pid: int): bool =
  var status: cint
  let res = waitpid(pid.Pid, status, WNOHANG)
  res == 0

proc waitForQuiet(
    child: PtyChild,
    buffer: var string,
    timeoutMs: int,
    quietMs: int,
    pollIntervalMs: int,
    marker: string = "",
): int =
  let started = getMonoTime()
  var lastRead = started
  var sawOutput = false
  result = -1

  while true:
    let beforeLen = buffer.len
    readAvailable(child, buffer)
    let now = getMonoTime()
    if buffer.len > beforeLen:
      sawOutput = true
      lastRead = now
      if marker.len > 0 and result < 0 and marker in buffer:
        result = int((now - started).inMilliseconds())
    elif not childRunning(child.pid):
      raise newException(IOError, "child exited before harness completed")

    let elapsedMs = int((now - started).inMilliseconds())
    if marker.len > 0 and result >= 0:
      return result

    if sawOutput and int((now - lastRead).inMilliseconds()) >= quietMs:
      return result

    if elapsedMs >= timeoutMs:
      raise newException(
        IOError,
        "timed out waiting for terminal state" &
          (if marker.len > 0: ": " & marker else: ""),
      )

    sleep(pollIntervalMs)

proc startPtyChild(binary: string): PtyChild =
  var master: cint
  var ws = WinSize(ws_row: 24, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
  let pid = forkpty(addr master, nil, nil, addr ws)

  if pid < 0:
    raiseOSError(osLastError())

  if pid == 0:
    putEnv("TERM", "xterm-256color")
    discard execl(binary.cstring, binary.cstring, nil)
    quit(127)

  result = PtyChild(pid: pid, master: master)
  setNonBlocking(result.master)

proc stopChild(child: PtyChild) =
  if child.pid > 0 and childRunning(child.pid):
    let esc = $char(27)
    try:
      writeAll(child.master, esc)
      sleep(100)
    except OSError:
      discard
    discard kill(child.pid.Pid, SIGTERM)
    sleep(50)
    if childRunning(child.pid):
      discard kill(child.pid.Pid, SIGKILL)
  discard close(child.master)

proc sampleJson(sample: ProcfsSample): JsonNode =
  %*{
    "pid": sample.pid,
    "vm_rss_kb": sample.vmRssKb,
    "vm_size_kb": sample.vmSizeKb,
    "rss_kb": sample.rssKb,
    "pss_kb": sample.pssKb,
    "private_dirty_kb": sample.privateDirtyKb,
    "shared_clean_kb": sample.sharedCleanKb,
    "rss_anon_kb": sample.rssAnonKb,
    "rss_file_kb": sample.rssFileKb
  }

proc enforceBudget(label: string, actual: int, maximum: int) =
  if maximum > 0 and actual > maximum:
    raise newException(
      IOError, label & " exceeded budget: actual=" & $actual & " max=" & $maximum
    )

proc main() =
  let opts = parseOptions()
  createDir(parentDir(opts.output))

  let child = startPtyChild(opts.binary)
  defer:
    stopChild(child)

  var screen = newStringOfCap(64 * 1024)
  discard waitForQuiet(
    child, screen, opts.startupTimeoutMs, opts.quietMs, opts.pollIntervalMs
  )

  let idleLocal = readProcfsSample(child.pid)

  screen.setLen(0)
  let aurStart = getMonoTime()
  writeAll(child.master, "aur/")
  let aurVisibleMs =
    waitForQuiet(
      child,
      screen,
      opts.markerTimeoutMs,
      opts.quietMs,
      opts.pollIntervalMs,
      "[Aur]",
    )
  let aurMarkerElapsedMs = if aurVisibleMs >= 0: aurVisibleMs
    else: int((getMonoTime() - aurStart).inMilliseconds())

  discard waitForQuiet(
    child, screen, opts.startupTimeoutMs, opts.quietMs, opts.pollIntervalMs
  )
  let postAur = readProcfsSample(child.pid)

  screen.setLen(0)
  writeAll(child.master, repeat(char(127), 4))
  discard waitForQuiet(
    child, screen, opts.startupTimeoutMs, opts.quietMs, opts.pollIntervalMs, "[Local]"
  )

  screen.setLen(0)
  writeAll(child.master, "nim/")
  let nimbleVisibleMs =
    waitForQuiet(
      child,
      screen,
      opts.markerTimeoutMs,
      opts.quietMs,
      opts.pollIntervalMs,
      "[Nimble]",
    )
  discard waitForQuiet(
    child, screen, opts.startupTimeoutMs, opts.quietMs, opts.pollIntervalMs
  )
  let postNimble = readProcfsSample(child.pid)

  let payload = %*{
    "binary": absolutePath(opts.binary),
    "output": absolutePath(opts.output),
    "environment": {
      "cwd": getCurrentDir(),
      "nim_version": firstLine(execProcess("nim --version")),
      "nimble_version": firstLine(execProcess("nimble --version")),
      "tool_build_mode": (when defined(release): "release" else: "debug"),
      "threads_enabled": compileOption("threads")
    },
    "timings_ms": {
      "aur_visible_ms": aurMarkerElapsedMs,
      "nimble_visible_ms": nimbleVisibleMs
    },
    "samples": {
      "idle_local": sampleJson(idleLocal),
      "post_aur": sampleJson(postAur),
      "post_nimble": sampleJson(postNimble)
    }
  }

  writeFile(opts.output, pretty(payload))
  echo pretty(payload)

  enforceBudget("idle_rss_kb", idleLocal.rssKb, opts.maxIdleRssKb)
  enforceBudget("idle_pss_kb", idleLocal.pssKb, opts.maxIdlePssKb)
  enforceBudget(
    "idle_private_dirty_kb", idleLocal.privateDirtyKb, opts.maxIdlePrivateDirtyKb
  )
  enforceBudget("aur_visible_ms", aurMarkerElapsedMs, opts.maxSwitchVisibleMs)
  enforceBudget("nimble_visible_ms", nimbleVisibleMs, opts.maxSwitchVisibleMs)

when isMainModule:
  main()
