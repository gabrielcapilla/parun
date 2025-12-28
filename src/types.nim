## This module defines the fundamental data structures following DOD principles.
##
## Key Principles:
## 1. **SoA (Structure of Arrays):** Data separation to maximize cache locality.
## 2. **Hot/Cold Splitting:** Separating frequently accessed data (search)
##    from rarely accessed data (details/rendering).
## 3. **Arenas:** Using contiguous buffers for strings to avoid fragmentation and GC.

import std/[tables, monotimes]

const
  ## Max number of package details cached in RAM.
  DetailsCacheLimit* = 16
  ## Buffer size for thread communication batches.
  BatchSize* = 64 * 1024

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

  MsgKind* = enum
    ## Message types for the Actor system (Threading).
    MsgInput
    MsgTick
    MsgSearchResults
    MsgDetailsLoaded
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

  PackageCold* = object
    ## "Cold" data accessed only when rendering or viewing details.
    ##
    ## These data are not loaded into cache during the search filtering phase.
    ##
    ## Length of version string.
    verLens*: seq[uint8]
    ## Index in the repository table (max 255 repos).
    repoIndices*: seq[uint8]
    ## Bitmask: bit 0 = installed.
    flags*: seq[uint8]

  PackageSOA* = object
    ## Main Structure of Arrays (SoA) container.
    ##
    ## Groups hot and cold data. Allows passing the entire dataset
    ## between functions without copying underlying data (seq references).
    hot*: PackageHot
    cold*: PackageCold

  ResultsBuffer* = object
    ## Fixed-size buffer for search results.
    ##
    ## Avoids dynamic allocations (GC) during filtering.
    ## Passed by value/reference, designed to reside on the Stack if possible.
    ##
    ## Real indices pointing to PackageSOA.
    indices*: array[2000, int32]
    ## SIMD relevance score.
    scores*: array[2000, int]
    ## Current count of valid results.
    count*: int

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
    of MsgDetailsLoaded:
      ## Requested package index.
      pkgIdx*: int32
      ## Formatted details text.
      content*: string
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

    # Search and UI State
    #
    ## Current filtered results.
    visibleIndices*: seq[int32]
    ## Bitset for multi-selection (64 pkgs per int).
    selectionBits*: seq[uint64]
    ## LRU cache for details.
    detailsCache*: Table[int32, string]

    ## Visual cursor position (index in visibleIndices).
    cursor*: int
    ## List scroll offset.
    scroll*: int
    ## User input.
    searchBuffer*: string
    ## Cursor position in input.
    searchCursor*: int

    # Modes and Flags
    searchMode*: SearchMode
    dataSource*: DataSource
    ## Mode to return to after exiting AUR/Nimble.
    baseSearchMode*: SearchMode
    baseDataSource*: DataSource
    ## Filter: View only selected?
    viewingSelection*: bool

    # Async and Control
    isSearching*: bool
    ## Incremental search request ID.
    searchId*: int
    ## ID associated with currently loaded data.
    dataSearchId*: int
    ## Dirty flag for rendering.
    needsRedraw*: bool
    shouldQuit*: bool
    shouldInstall*: bool
    shouldUninstall*: bool
    showDetails*: bool
    justReceivedSearchResults*: bool
    statusMessage*: string

    ## Scroll of the details panel.
    detailScroll*: int

    # Optimizations
    ## Per-frame temporary arena.
    stringArena*: StringArena
    ## For debouncing.
    lastInputTime*: MonoTime
    debouncePending*: bool
