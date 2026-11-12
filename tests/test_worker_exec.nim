import std/[monotimes, os, strutils, times, unittest]

import ../src/catalog/model
import ../src/sources/worker_exec
import ./helpers

suite "bounded worker process output":
  test "detail payloads share the configured hard limit":
    let content = repeat('x', MaxDetailPayloadBytes + 32)
    let bounded = clampDetailPayload(content)
    check bounded.len == MaxDetailPayloadBytes
    check bounded.endsWith("\n\n[truncated]")
    check bounded[0 ..< MaxDetailPayloadBytes - "\n\n[truncated]".len] ==
      content[0 ..< MaxDetailPayloadBytes - "\n\n[truncated]".len]

  test "strict execution rejects a nonzero process exit":
    let root = getTempDir() / ("parun-worker-output-exit-" & $getCurrentProcessId())
    removeTree(root)
    createDir(root)
    defer:
      removeTree(root)
    let producer = root / "producer"
    writeFile(producer, "#!/bin/sh\nprintf 'failed'\nexit 7\n")
    setFilePermissions(producer, {fpUserRead, fpUserExec})

    let (output, success) = execWithErrorCheck(producer, maxOutputBytes = 64)
    check not success
    check output.len == 0

  test "rejects a response larger than the configured limit":
    let root = getTempDir() / ("parun-worker-output-" & $getCurrentProcessId())
    removeTree(root)
    createDir(root)
    defer:
      removeTree(root)
    let producer = root / "producer"
    writeFile(producer, "#!/bin/sh\nprintf '0123456789abcdef0123456789abcdef'\n")
    setFilePermissions(producer, {fpUserRead, fpUserExec})

    let (output, success) = execWithErrorCheck(producer, maxOutputBytes = 16)
    check not success
    check output.len == 0

  test "retains a response inside the configured limit":
    let root = getTempDir() / ("parun-worker-output-small-" & $getCurrentProcessId())
    removeTree(root)
    createDir(root)
    defer:
      removeTree(root)
    let producer = root / "producer"
    writeFile(producer, "#!/bin/sh\nprintf 'bounded'\n")
    setFilePermissions(producer, {fpUserRead, fpUserExec})

    let (output, success) = execWithErrorCheck(producer, maxOutputBytes = 64)
    check success
    check output == "bounded"

  test "network process deadline terminates a stalled downloader":
    let root = getTempDir() / ("parun-worker-output-timeout-" & $getCurrentProcessId())
    removeTree(root)
    createDir(root)
    defer:
      removeTree(root)
    let producer = root / "curl"
    writeFile(producer, "#!/bin/sh\nexec sleep 2\n")
    setFilePermissions(producer, {fpUserRead, fpUserExec})
    let oldPath = getEnv("PATH", "")
    putEnv("PATH", root & PathSep & oldPath)
    defer:
      if oldPath.len > 0:
        putEnv("PATH", oldPath)
      else:
        delEnv("PATH")

    let started = getMonoTime()
    expect DownloadError:
      discard
        downloadWithRetry("https://example.invalid", maxRetries = 1, timeoutMs = 100)
    check int((getMonoTime() - started).inMilliseconds()) < 1_000
