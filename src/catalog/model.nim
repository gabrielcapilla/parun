import std/[monotimes, sets, strutils]
import ../diagnostics/memory_accounting
import ../index/indexes

const
  DetailsCacheLimit* = 64

  DetailsCacheByteBudget* = 262144

  MaxDetailPayloadBytes* = 16 * 1024

  DetailsRequestDebounceMs* = 0

  DetailCacheBlockBytes* = 256

  KeyNull* = char(0)
  KeyCtrlA* = char(1)
  KeyCtrlD* = char(4)
  KeyCtrlE* = char(5)
  KeyBackspace* = char(8)
  KeyTab* = char(9)
  KeyCtrlJ* = char(10)
  KeyCtrlK* = char(11)
  KeyEnter* = char(13)
  KeyCtrlN* = char(14)
  KeyCtrlR* = char(18)
  KeyCtrlS* = char(19)
  KeyCtrlU* = char(21)
  KeyCtrlY* = char(25)
  KeyEsc* = char(27)
  KeySpace* = char(32)
  KeyBack* = char(127)
  KeyAltBackspace* = char(29)

  KeyDelete* = char(209)
  KeyCtrlLeft* = char(220)
  KeyCtrlRight* = char(221)

  KeyUp* = char(200)
  KeyDown* = char(201)
  KeyLeft* = char(202)
  KeyRight* = char(203)
  KeyPageUp* = char(204)
  KeyPageDown* = char(205)
  KeyHome* = char(206)
  KeyEnd* = char(207)
  KeyF1* = char(210)

  AnsiReset* = "\e[0m"
  AnsiBold* = "\e[1m"
  AnsiDim* = "\e[2m"
  ColorRepo* = "\e[95m"
  ColorPkg* = "\e[97m"
  ColorVer* = "\e[92m"
  ColorState* = "\e[36m"
  ColorSel* = "\e[93m"
  ColorPrompt* = "\e[36m"
  ColorHighlightBg* = "\e[48;5;235m"

  ColorModeLocal* = "\e[1;32m"
  ColorModeAur* = "\e[1;35m"
  ColorModeNimble* = "\e[1;33m"
  ColorModeReview* = "\e[1;33m"

func limitDetailPayload*(content: string): string =
  if content.len <= MaxDetailPayloadBytes:
    return content
  const Suffix = "\n\n[truncated]"
  let keep = max(0, MaxDetailPayloadBytes - Suffix.len)
  result = content[0 ..< keep]
  result.add(Suffix)

type
  SearchMode* = enum
    ModeLocal
    ModeAUR

  DataSource* = enum
    SourceSystem
    SourceNimble

  SourceSlot* = enum
    SlotSystem
    SlotAur
    SlotNimble
    SlotMerged

  DetailAnimationStyle* = enum
    DetailAnimationBlocks
    DetailAnimationFade

  DetailAnimationSpeed* = enum
    DetailAnimationFast
    DetailAnimationNormal
    DetailAnimationSlow
    DetailAnimationUltraSlow

  MsgKind* = enum
    MsgInput
    MsgTick
    MsgDetailsLoaded
    MsgWorkerDiagnostics
    MsgError

  DetailQuality* = enum
    DetailSummary
    DetailManifest
    DetailFallback

  RequestDetailsProc* = proc(
    idx: int32,
    name, repo, url: string,
    source: DataSource,
    slot: SourceSlot,
    detailGeneration: uint64,
  ) {.gcsafe.}

var requestDetailsImpl*: RequestDetailsProc

proc installRequestDetailsDispatch*(details: RequestDetailsProc) =
  requestDetailsImpl = details

proc requestDetails*(
    idx: int32,
    name, repo, url: string,
    source: DataSource,
    slot: SourceSlot,
    detailGeneration: uint64,
) {.inline.} =
  if requestDetailsImpl != nil:
    requestDetailsImpl(idx, name, repo, url, source, slot, detailGeneration)

type
  Msg* = object
    case kind*: MsgKind
    of MsgInput:
      key*: char
    of MsgTick:
      discard
    of MsgDetailsLoaded:
      pkgIdx*: int32

      pkgSlot*: SourceSlot

      detailGeneration*: uint64

      quality*: DetailQuality

      content*: string
    of MsgWorkerDiagnostics:
      workerReport*: WorkerMemoryReport
    of MsgError:
      errMsg*: string

      errorDetailIdx*: int32
      errorDetailSlot*: SourceSlot
      errorDetailGeneration*: uint64

  DetailCacheEntry* = object
    key*: int32
    start*: uint32
    encodedLen*: uint16
    rawLen*: uint16
    valid*: bool

  DetailCache* = object
    arena*: seq[char]
    arenaUsed*: int
    entries*: array[DetailsCacheLimit, DetailCacheEntry]
    count*: int
    nextEvict*: int

  DetailScramble* = object
    pkgIdx*: int32
    pkgSlot*: SourceSlot
    startedAt*: MonoTime
    durationMs*: int
    active*: bool

  PerfCounters* = object
    hotFilterCalls*: uint64
    hotFilterCandidates*: uint64
    hotScoreCalls*: uint64
    hotInstalledChecks*: uint64
    hotBucketLookups*: uint64

    coldRowRenders*: uint64
    coldDetailWraps*: uint64
    coldDetailLines*: uint64
    coldDetailCacheHits*: uint64
    coldDetailCacheMisses*: uint64
    coldDetailRequests*: uint64

  AppState* = object
    sourceViews*: array[SourceSlot, SourceIndexView]

    visibleIndices*: seq[int32]

    visibleAll*: bool

    visibleAllCount*: int32

    selectedPackages*: HashSet[string]

    detailsCache*: DetailCache

    cursor*: int

    scroll*: int

    searchBuffer*: string

    searchCursor*: int

    detailScroll*: int
    lastDetailWidth*: int

    lastInputTime*: MonoTime
    detailTargetSince*: MonoTime

    statusMessage*: string

    wrappedDetails*: seq[string]

    lastDetailIdx*: int32
    pendingDetailIdx*: int32
    detailScramble*: DetailScramble
    searchMode*: SearchMode
    dataSource*: DataSource

    baseSearchMode*: SearchMode
    baseDataSource*: DataSource

    baseSlot*: SourceSlot

    explicitSourceSelection*: bool

    enabledSlots*: set[SourceSlot]

    runtimeIndexDir*: string
    activeSlot*: SourceSlot
    sourceIndexStamps*: array[SourceSlot, int64]
    lastIndexPollTime*: MonoTime
    pendingDetailSlot*: SourceSlot
    detailRequestInFlight*: bool

    detailEnrichmentInFlight*: bool
    detailEnrichmentIdx*: int32
    detailEnrichmentSlot*: SourceSlot

    detailGeneration*: uint64

    perf*: PerfCounters

    viewingSelection*: bool
    indexRefreshInFlight*: bool

    needsRedraw*: bool
    shouldQuit*: bool
    shouldInstall*: bool
    shouldUninstall*: bool
    showDetails*: bool
    detailsAnimationEnabled*: bool
    detailAnimationStyle*: DetailAnimationStyle
    detailAnimationSpeed*: DetailAnimationSpeed
    debouncePending*: bool

func getEffectiveQuery*(buffer: string): string {.noSideEffect.} =
  if buffer.startsWith("aur/"):
    return buffer[4 ..^ 1]
  if buffer.startsWith("a/"):
    return buffer[2 ..^ 1]
  if buffer.startsWith("nimble/"):
    return buffer[7 ..^ 1]
  if buffer.startsWith("nim/"):
    return buffer[4 ..^ 1]
  if buffer.startsWith("n/"):
    return buffer[2 ..^ 1]
  if buffer.startsWith("installed/"):
    return buffer[10 ..^ 1]
  if buffer.startsWith("i/"):
    return buffer[2 ..^ 1]
  return buffer

proc slotToIndexKind*(slot: SourceSlot): IndexedSourceKind {.inline.} =
  case slot
  of SlotSystem: iskSystem
  of SlotAur: iskAur
  of SlotNimble: iskNimble
  of SlotMerged: iskSystem

proc sourceSlot*(source: DataSource, mode: SearchMode): SourceSlot {.inline.} =
  case source
  of SourceNimble:
    SlotNimble
  of SourceSystem:
    if mode == ModeAUR: SlotAur else: SlotSystem
