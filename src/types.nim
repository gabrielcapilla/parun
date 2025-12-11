import std/[sets, tables]

const
  KeyEnter* = char(13)
  KeyEsc* = char(27)
  KeyTab* = char(9)
  KeyBack* = char(127)
  KeyBackspace* = char(8)

  KeyUp* = char(11)
  KeyDown* = char(10)
  KeyLeft* = char(2)
  KeyRight* = char(6)

  KeyPageUp* = char(23)
  KeyPageDown* = char(24)
  KeyHome* = char(25)
  KeyEnd* = char(26)

  KeyCtrlR* = char(18)
  KeyCtrlA* = char(1)
  KeyF1* = char(133)

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
  ColorModeHybrid* = "\e[1;35m"

type
  CompactPackage* = object
    repoIdx*: uint8
    nameOffset*: int32
    nameLen*: int16
    verOffset*: int32
    verLen*: int16
    isInstalled*: bool

  SearchMode* = enum
    ModeLocal
    ModeHybrid

  MsgKind* = enum
    MsgInput
    MsgTick
    MsgSearchResults
    MsgDetailsLoaded
    MsgError

  Msg* = object
    case kind*: MsgKind
    of MsgInput:
      key*: char
    of MsgTick:
      discard
    of MsgSearchResults:
      packedPkgs*: seq[CompactPackage]
      poolData*: string
      repos*: seq[string]
      searchId*: int
      isAppend*: bool
    of MsgDetailsLoaded:
      pkgId*: string
      content*: string
    of MsgError:
      errMsg*: string

  AppState* = object
    pkgs*: seq[CompactPackage]
    stringPool*: string
    repoList*: seq[string]

    localPkgCount*: int
    localPoolLen*: int
    localRepoCount*: int

    visibleIndices*: seq[int32]
    selected*: HashSet[string]

    detailsCache*: Table[string, string]
    cursor*: int
    scroll*: int
    searchBuffer*: string
    searchCursor*: int

    searchMode*: SearchMode

    isSearching*: bool
    searchId*: int
    needsRedraw*: bool
    shouldQuit*: bool
    shouldInstall*: bool
    shouldUninstall*: bool
    showDetails*: bool
    justReceivedSearchResults*: bool
