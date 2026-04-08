## This module defines the fundamental data structures following DOD principles.
##
## Key Principles:
## 1. **SoA (Structure of Arrays):** Data separation to maximize cache locality.
## 2. **Hot/Cold Splitting:** Separating frequently accessed data (search)
##    from rarely accessed data (details/rendering).
## 3. **Arenas:** Using contiguous buffers for strings to avoid fragmentation and GC.

import std/[monotimes, strutils]
import ../utils/memory_accounting
import ../storage/indexes

const
  ## Max number of package details cached in RAM.
  DetailsCacheLimit* = 8
  ## Approximate UI-side byte budget for cached detail text.
  DetailsCacheByteBudget* = 128 * 1024
  ## Hard cap for a single details payload kept in memory.
  MaxDetailPayloadBytes* = 16 * 1024
  ## Delay before requesting details for a newly focused package.
  DetailsRequestDebounceMs* = 0
  ## Compression block size for cold details payload storage.
  DetailCacheBlockBytes* = 256
  ## Buffer size for thread communication batches.
  # BatchSize moved to worker_types.nim

  # Key and ANSI Constants
  KeyNull* = char(0)
  KeyCtrlA* = char(1)
  KeyCtrlD* = char(4)
  KeyCtrlE* = char(5)
  KeyBackspace* = char(8)
  KeyTab* = char(9)
  KeyCtrlJ* = char(10)
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

type
  SearchMode* = enum
    ## Defines the current search context within the package system.
    ##
    ## Search in local repositories (pacman -Sl).
    ModeLocal
    ## Search in Arch User Repository.
    ModeAUR

  DataSource* = enum
    ## Defines the active data backend.
    ##
    ## Pacman/AUR.
    SourceSystem
    ## Nimble ecosystem.
    SourceNimble

  SourceSlot* = enum
    SlotSystem
    SlotAur
    SlotNimble
    SlotMerged

  MsgKind* = enum
    ## Message types for the Actor system (Threading).
    MsgInput
    MsgTick
    MsgSearchResults
    MsgDetailsLoaded
    MsgWorkerDiagnostics
    MsgError

  PackageHot* = object
    ## "Hot" data accessed every frame during search.
    ##
    ## Kept separate to maximize L1/L2 cache efficiency.
    ## When iterating over names, we don't pollute cache with versions or flags.
    ##
    ## Offsets in `textArena` where names start.
    locators*: seq[uint32]
    ## Length of names (max 255 chars).
    nameLens*: seq[uint8]
    ## Bitmask: bit 0 = installed. (Moved to hot for faster filtering)
    flags*: seq[uint8]

  PackageCold* = object
    ## "Cold" data accessed only when rendering or viewing details.
    ##
    ## These data are not loaded into cache during the search filtering phase.
    ##
    ## Length of version string.
    verLens*: seq[uint8]
    ## Index in the repository table (max 255 repos).
    repoIndices*: seq[uint8]

  PackageSOA* = object
    ## Main Structure of Arrays (SoA) container.
    ##
    ## Groups hot and cold data. Allows passing the entire dataset
    ## between functions without copying underlying data (seq references).
    hot*: PackageHot
    cold*: PackageCold

  RequestLoadProc* = proc(id: int) {.gcsafe.}
  RequestSearchProc* = proc(query: string, id: int) {.gcsafe.}
  RequestDetailsProc* = proc(
    idx: int32, name, repo: string, source: DataSource, slot: SourceSlot
  ) {.gcsafe.}

var
  requestLoadAllImpl*: RequestLoadProc
  requestLoadAurImpl*: RequestLoadProc
  requestLoadNimbleImpl*: RequestLoadProc
  requestSearchImpl*: RequestSearchProc
  requestDetailsImpl*: RequestDetailsProc

proc installRequestDispatch*(
    loadAll, loadAur, loadNimble: RequestLoadProc,
    search: RequestSearchProc,
    details: RequestDetailsProc,
) =
  requestLoadAllImpl = loadAll
  requestLoadAurImpl = loadAur
  requestLoadNimbleImpl = loadNimble
  requestSearchImpl = search
  requestDetailsImpl = details

proc dispatchLoad(impl: RequestLoadProc, id: int) {.inline.} =
  if impl != nil:
    impl(id)

proc requestLoadAll*(id: int) {.inline.} =
  dispatchLoad(requestLoadAllImpl, id)

proc requestLoadAur*(id: int) {.inline.} =
  dispatchLoad(requestLoadAurImpl, id)

proc requestLoadNimble*(id: int) {.inline.} =
  dispatchLoad(requestLoadNimbleImpl, id)

proc requestSearch*(query: string, id: int) {.inline.} =
  if requestSearchImpl != nil:
    requestSearchImpl(query, id)

proc requestDetails*(
    idx: int32, name, repo: string, source: DataSource, slot: SourceSlot
) {.inline.} =
  if requestDetailsImpl != nil:
    requestDetailsImpl(idx, name, repo, source, slot)

type
  StringArenaHandle* = object
    ## Lightweight reference to a string within a `StringArena`.
    ##
    ## Replaces standard `string` type to avoid GC in the render loop.
    ##
    ## Start position in the buffer.
    startOffset*: int
    ## Length in bytes.
    length*: int

  StringArena* = object
    ## Linear Allocator (Arena) for temporary strings.
    ##
    ## Reset every frame. Allows building UI strings without
    ## fragmenting memory or triggering the Garbage Collector.
    ##
    ## Pre-reserved contiguous memory.
    buffer*: seq[char]
    ## Total available size.
    capacity*: int
    ## Current write pointer.
    offset*: int

  ## Immutable message for inter-thread communication (Actor Model).
  Msg* = object
    case kind*: MsgKind
    of MsgInput:
      key*: char
    of MsgTick:
      discard
    of MsgSearchResults:
      ## Partial or full results.
      soa*: PackageSOA
      ## Text chunk to append to main arena.
      textChunk*: string
      ## List of new repositories.
      repos*: seq[string]
      ## ID to discard obsolete searches.
      searchId*: int
      ## True = append to results, False = replace.
      isAppend*: bool
      ## Performance telemetry.
      durationMs*: int
      ## Request Origin/Target
      reqSource*: DataSource
      reqMode*: SearchMode
    of MsgDetailsLoaded:
      ## Requested package index.
      pkgIdx*: int32
      ## Source slot associated with the request.
      pkgSlot*: SourceSlot
      ## Formatted details text.
      content*: string
    of MsgWorkerDiagnostics:
      workerReport*: WorkerMemoryReport
    of MsgError:
      errMsg*: string

  PackageDB* = object
    ## In-memory persistent database for a specific source.
    ##
    ## Allows instant switching between Local, AUR, and Nimble without reloading.
    soa*: PackageSOA
    ## Main arena for names/versions.
    textArena*: seq[char]
    ## Unique repository names.
    repos*: seq[string]
    ## Optimized arena for repo names.
    repoArena*: seq[char]
    ## Lengths of repo names.
    repoLens*: seq[uint8]
    ## Offsets in repoArena.
    repoOffsets*: seq[uint16]
    ## Flag to avoid unnecessary reloads.
    isLoaded*: bool

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

  PerfCounters* = object ## Hot-path counters (search/filtering).
    hotFilterCalls*: uint64
    hotFilterCandidates*: uint64
    hotScoreCalls*: uint64
    hotInstalledChecks*: uint64
    hotBucketLookups*: uint64
    ## Cold-path counters (render/details).
    coldRowRenders*: uint64
    coldDetailWraps*: uint64
    coldDetailLines*: uint64
    coldDetailCacheHits*: uint64
    coldDetailCacheMisses*: uint64
    coldDetailRequests*: uint64

  AppState* = object
    ## "God Object" containing all mutable application state.
    ##
    ## Following DOD, systems (functions) transform this state.

    #  Mutable Views (Pointers to active DB)
    soa*: PackageSOA
    textArena*: seq[char]
    repos*: seq[string]
    repoArena*: seq[char]
    repoLens*: seq[uint8]
    repoOffsets*: seq[uint16]

    # Persistent Storage
    #
    ## System packages cache (pacman).
    systemDB*: PackageDB
    ## AUR packages cache.
    aurDB*: PackageDB
    ## Nimble packages cache.
    nimbleDB*: PackageDB
    ## Immutable, mmapped source indexes keyed by runtime source slot.
    sourceViews*: array[SourceSlot, SourceIndexView]

    # Search and UI State
    #
    ## Current filtered results (materialized only when not in identity mode).
    visibleIndices*: seq[int32]
    ## True when visible list is an implicit identity mapping [0..N).
    visibleAll*: bool
    ## Number of visible rows when `visibleAll` is true.
    visibleAllCount*: int32
    ## Bitset for multi-selection (64 pkgs per int).
    selectionBits*: seq[uint64]
    ## Bounded details cache with fixed metadata and arena-backed payload.
    detailsCache*: DetailCache

    ## Visual cursor position (index in visibleIndices).
    cursor*: int
    ## List scroll offset.
    scroll*: int
    ## User input.
    searchBuffer*: string
    ## Cursor position in input.
    searchCursor*: int

    # Async and Control
    ## Incremental search request ID.
    searchId*: int
    ## ID associated with currently loaded data.
    dataSearchId*: int
    ## Scroll of the details panel.
    detailScroll*: int
    lastDetailWidth*: int
    ## For debouncing.
    lastInputTime*: MonoTime
    detailTargetSince*: MonoTime

    statusMessage*: string

    # Optimizations
    ## Per-frame temporary arena.
    stringArena*: StringArena

    # Details wrapping cache
    wrappedDetails*: seq[string]

    # Modes
    lastDetailIdx*: int32
    pendingDetailIdx*: int32
    searchMode*: SearchMode
    dataSource*: DataSource
    ## Mode to return to after exiting AUR/Nimble.
    baseSearchMode*: SearchMode
    baseDataSource*: DataSource
    ## Runtime slot to return to when no search prefix is active.
    baseSlot*: SourceSlot
    ## True when source flags were passed explicitly on startup.
    explicitSourceSelection*: bool
    ## Sources enabled by CLI flags.
    enabledSlots*: set[SourceSlot]
    ## Runtime directory where immutable indexes are stored.
    runtimeIndexDir*: string
    activeSlot*: SourceSlot
    pendingDetailSlot*: SourceSlot
    detailRequestInFlight*: bool
    ## Runtime perf counters used by automated harness assertions.
    perf*: PerfCounters

    # Packed flags
    ## Filter: View only selected?
    viewingSelection*: bool
    isSearching*: bool
    ## Dirty flag for rendering.
    needsRedraw*: bool
    shouldQuit*: bool
    shouldInstall*: bool
    shouldUninstall*: bool
    showDetails*: bool
    justReceivedSearchResults*: bool
    debouncePending*: bool

func isInstalled*(soa: PackageSOA, idx: int): bool {.inline, noSideEffect.} =
  ## Checks if a package is installed using bitwise operations.
  (soa.hot.flags[idx] and 1) != 0

func getEffectiveQuery*(buffer: string): string {.noSideEffect.} =
  ## Extracts the real query by removing magic prefixes and their aliases.
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
