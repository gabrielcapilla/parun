import std/[monotimes, os, osproc, streams, times]
import ../catalog/model

type
  ExecResult* = tuple[output: string, success: bool]

  ExecMode* = enum
    emStrict
    emLenient

  DownloadError* = object of IOError

const DefaultProcessOutputLimit* = 8 * 1024 * 1024

proc readProcessOutput(
    process: Process, maxBytes: int
): tuple[output: string, bounded: bool] =
  let stream = process.outputStream
  var chunk: array[8192, char]
  result.output = newStringOfCap(min(maxBytes, 64 * 1024))
  while true:
    let count = stream.readData(addr chunk[0], chunk.len)
    if count <= 0:
      break
    if maxBytes > 0 and result.output.len + count > maxBytes:
      process.kill()
      discard process.waitForExit()
      result.output.setLen(0)
      result.bounded = false
      return
    let oldLen = result.output.len
    result.output.setLen(oldLen + count)
    copyMem(addr result.output[oldLen], addr chunk[0], count)
  result.bounded = true

proc waitForProcessBounded(
    process: Process, timeoutMs: int
): tuple[exitCode: int, timedOut: bool] =
  if timeoutMs <= 0:
    return (process.waitForExit(), false)

  let started = getMonoTime()
  while process.running:
    let elapsedMs = int((getMonoTime() - started).inMilliseconds())
    if elapsedMs >= timeoutMs:
      try:
        process.kill()
      except OSError:
        discard
      discard process.waitForExit()
      return (-1, true)
    sleep(min(10, max(1, timeoutMs - elapsedMs)))
  (process.waitForExit(), false)

proc execWithErrorCheck*(
    exe: string,
    args: openArray[string] = [],
    mode: ExecMode = emStrict,
    maxOutputBytes: int = DefaultProcessOutputLimit,
    timeoutMs: int = -1,
): ExecResult =
  let process = startProcess(exe, args = args, options = {poUsePath, poStdErrToStdOut})
  var exitCode: int
  var timedOut = false
  if timeoutMs > 0:
    (exitCode, timedOut) = waitForProcessBounded(process, timeoutMs)
  let (output, bounded) = readProcessOutput(process, maxOutputBytes)
  if timeoutMs <= 0:
    exitCode = process.waitForExit()
  process.close()

  if timedOut or not bounded:
    return ("", false)

  case mode
  of emStrict:
    if exitCode != 0:
      return ("", false)
  of emLenient:
    discard

  (output, true)

proc downloadWithRetry*(
    url: string,
    maxRetries: int = 3,
    timeoutMs: int = 10_000,
    maxOutputBytes: int = MaxDetailPayloadBytes * 4,
): string =
  var lastError = ""
  let started = getMonoTime()
  for i in 0 ..< maxRetries:
    let elapsedMs = int((getMonoTime() - started).inMilliseconds())
    let remainingMs = timeoutMs - elapsedMs
    if remainingMs <= 0:
      break
    let curlTimeoutSeconds = max(1, min(3, (remainingMs + 999) div 1000))
    try:
      let (output, success) = execWithErrorCheck(
        "curl",
        [
          "-q",
          "--silent",
          "--show-error",
          "--fail",
          "--location",
          "--max-time",
          $curlTimeoutSeconds,
          "--proto",
          "=http,https",
          "--proto-redir",
          "=http,https",
          "--",
          url,
        ],
        emStrict,
        maxOutputBytes,
        remainingMs,
      )
      if success:
        return output
      lastError = "curl exited unsuccessfully"
    except CatchableError as e:
      lastError = e.msg
    if i < maxRetries - 1:
      let afterAttemptMs = int((getMonoTime() - started).inMilliseconds())
      let delayMs = min(1000 * (1 shl i), max(0, timeoutMs - afterAttemptMs))
      if delayMs > 0:
        sleep(delayMs)

  raise newException(
    DownloadError, "Failed to download after " & $maxRetries & " attempts: " & lastError
  )

proc clampDetailPayload*(content: string): string =
  limitDetailPayload(content)
