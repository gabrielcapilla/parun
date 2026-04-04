import std/[algorithm, json, monotimes, os, osproc, parseopt, strutils, tables, times]
import ../src/core/[state, types]
import ../src/core/systems/update_system
import ../src/pkgs/manager
import ../src/storage/indexes
import ../src/utils/[memory_accounting, procfs_metrics]

type
  Options = object
    output: string
    timeoutMs: int
    quietMs: int
    pollMs: int

proc firstLine(text: string): string =
  for line in text.splitLines():
    if line.len > 0:
      return line
  ""

proc parseOptions(): Options =
  result = Options(
    output: getCurrentDir() / "tools/output/byte_accounting.json",
    timeoutMs: 120000,
    quietMs: 1000,
    pollMs: 25,
  )

  var p = initOptParser()
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdLongOption:
      case p.key
      of "output":
        result.output = p.val
      of "timeout-ms":
        result.timeoutMs = parseInt(p.val)
      of "quiet-ms":
        result.quietMs = parseInt(p.val)
      of "poll-ms":
        result.pollMs = parseInt(p.val)
      else:
        raise newException(ValueError, "unknown option --" & p.key)
    else:
      raise newException(ValueError, "unexpected argument: " & p.key)

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

proc sectionJson(section: MemorySection): JsonNode =
  result = %*{
    "name": section.name,
    "bytes": section.sectionBytes(),
    "metrics": newJArray()
  }
  for metric in section.metrics:
    result["metrics"].add(
      %*{
        "name": metric.name,
        "bytes": metric.bytes,
        "length": metric.length,
        "capacity": metric.capacity,
        "note": metric.note
      }
    )

proc appStateSections(state: AppState): seq[MemorySection] =
  var runtimeSection = MemorySection(name: "runtime_state")
  runtimeSection.addScalarMetric("app_state_struct", sizeof(AppState))
  runtimeSection.addScalarMetric(
    "active_slot",
    0,
    note = "Current runtime source slot: " & $state.activeSlot,
  )

  var uiSection = MemorySection(name: "ui_state")
  uiSection.addSeqMetric("visible_indices", state.visibleIndices)
  uiSection.addSeqMetric("selection_bits", state.selectionBits)
  uiSection.addTableMetric("details_cache", state.detailsCache)
  uiSection.addStringMetric("search_buffer", state.searchBuffer)
  uiSection.addStringMetric("status_message", state.statusMessage)
  uiSection.addSeqMetric("wrapped_details", state.wrappedDetails)
  uiSection.addSeqMetric("string_arena_buffer", state.stringArena.buffer)

  var mappedSection = MemorySection(name: "mapped_indexes")
  for slot in SourceSlot:
    let view = addr state.sourceViews[slot]
    mappedSection.addScalarMetric(
      $slot & ".file_size",
      view[].fileSize,
      "Mapped immutable source index footprint on disk",
    )
    mappedSection.addScalarMetric(
      $slot & ".hot_bytes",
      mappedHotBytes(view),
      "Hot search bytes addressable through mmap",
    )
    mappedSection.addScalarMetric(
      $slot & ".cold_bytes",
      mappedColdBytes(view),
      "Cold display/detail bytes addressable through mmap",
    )

  result = @[
    runtimeSection,
    uiSection,
    mappedSection,
  ]

proc waitForQuiescence(
    state: var AppState,
    pendingMsgs: var seq[Msg],
    timeoutMs: int,
    quietMs: int,
    pollMs: int,
    loaded: proc(): bool,
    workerReport: var WorkerMemoryReport,
) =
  let started = getMonoTime()
  var lastMessage = started
  var sawMessage = false

  while true:
    pollWorkerMessages(pendingMsgs)
    if pendingMsgs.len > 0:
      sawMessage = true
      lastMessage = getMonoTime()
      for i in 0 ..< pendingMsgs.len:
        case pendingMsgs[i].kind
        of MsgWorkerDiagnostics:
          workerReport = pendingMsgs[i].workerReport
        of MsgError:
          raise newException(IOError, pendingMsgs[i].errMsg)
        else:
          update(state, pendingMsgs[i], 20)
    elif sawMessage and loaded() and int((getMonoTime() - lastMessage).inMilliseconds()) >=
        quietMs:
      return

    if int((getMonoTime() - started).inMilliseconds()) >= timeoutMs:
      raise newException(IOError, "timed out while waiting for package load quiescence")

    sleep(pollMs)

proc topContributors(sections: openArray[MemorySection], limit: int): JsonNode =
  var flat = newSeq[MemoryMetric]()
  for section in sections:
    for item in section.metrics:
      if item.bytes > 0:
        flat.add(MemoryMetric(name: section.name & "." & item.name, bytes: item.bytes))

  flat.sort(proc(a, b: MemoryMetric): int = cmp(b.bytes, a.bytes))

  result = newJArray()
  for i in 0 ..< min(limit, flat.len):
    result.add(%*{"name": flat[i].name, "bytes": flat[i].bytes})

proc main() =
  let opts = parseOptions()
  createDir(parentDir(opts.output))

  var state = newState(ModeLocal, true, false)
  var pendingMsgs = newSeqOfCap[Msg](32)
  var workerReport = WorkerMemoryReport()

  initPackageManager()
  defer:
    closeIndexedSources(state)
    shutdownPackageManager()

  state.prepareIndexedSources()
  let selfSample = readProcfsSample(getCurrentProcessId().int)

  requestWorkerDiagnostics()
  waitForQuiescence(
    state,
    pendingMsgs,
    opts.timeoutMs,
    opts.quietMs,
    opts.pollMs,
    proc(): bool = workerReport.sections.len > 0,
    workerReport,
  )

  let appSections = appStateSections(state)

  var appSectionsJson = newJArray()
  for section in appSections:
    appSectionsJson.add(sectionJson(section))

  var workerSectionsJson = newJArray()
  for section in workerReport.sections:
    workerSectionsJson.add(sectionJson(section))

  var appOwnedBytes = 0
  var mappedBytes = 0
  for section in appSections:
    if section.name == "mapped_indexes":
      mappedBytes += section.sectionBytes()
    else:
      appOwnedBytes += section.sectionBytes()

  let payload = %*{
    "environment": {
      "cwd": getCurrentDir(),
      "nim_version": firstLine(execProcess("nim --version")),
      "nimble_version": firstLine(execProcess("nimble --version")),
      "tool_build_mode": (when defined(release): "release" else: "debug"),
      "threads_enabled": compileOption("threads")
    },
    "procfs_sample": sampleJson(selfSample),
    "totals": {
      "app_owned_bytes": appOwnedBytes,
      "mapped_bytes": mappedBytes,
      "worker_owned_bytes": workerReport.reportBytes()
    },
    "app_sections": appSectionsJson,
    "worker_sections": workerSectionsJson,
    "top_contributors": topContributors(appSections, 12)
  }

  writeFile(opts.output, pretty(payload))
  echo pretty(payload)

when isMainModule:
  main()
