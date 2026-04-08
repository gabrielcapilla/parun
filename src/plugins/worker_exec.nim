import std/[os, osproc, httpclient, net]
import ../core/types

type
  ExecResult* = tuple[output: string, success: bool]
  ExecMode* = enum
    emStrict ## Non-zero exit code = failure (for critical commands)
    emLenient ## Empty output is acceptable even with non-zero (for search)

proc execWithErrorCheck*(cmd: string, mode: ExecMode = emStrict): ExecResult =
  ## Executes command with appropriate error handling based on mode.
  let (output, exitCode) = execCmdEx(cmd)

  case mode
  of emStrict:
    if exitCode != 0:
      return ("", false)
  of emLenient:
    discard

  (output, true)

proc downloadWithRetry*(client: HttpClient, url: string, maxRetries: int = 3): string =
  ## Downloads content with exponential backoff retry logic.
  var lastError = ""
  for i in 0 ..< maxRetries:
    try:
      return client.getContent(url)
    except Exception as e:
      lastError = e.msg
      if i < maxRetries - 1:
        sleep(1000 * (1 shl i))

  raise newException(
    HttpRequestError,
    "Failed to download after " & $maxRetries & " attempts: " & lastError,
  )

proc clampDetailPayload*(content: string): string =
  if content.len <= MaxDetailPayloadBytes:
    return content
  const Suffix = "\n\n[truncated]"
  let keep = max(0, MaxDetailPayloadBytes - Suffix.len)
  result = content[0 ..< keep]
  result.add(Suffix)
