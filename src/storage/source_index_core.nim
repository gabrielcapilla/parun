import std/[memfiles, tables]

const
  SourceIndexMagic* = "PRIX"
  SourceIndexVersion* = 5'u32
  LegacySourceIndexVersion* = 4'u32
  SourceIndexHeaderBytes* = 32'u32
  SectionNameBytes* = 16
  BucketCount* = 256
  PackedWord24Bytes* = 3
  PackedWord32Bytes* = 4
  PackedWord24Limit* = 0x00FF_FFFF'u32
  HeaderFlagWideWords* = 1'u32
  HeaderFlagNarrowRepoIdx* = 1'u32 shl 1
  HeaderFlagVerBlobCompressed* = 1'u32 shl 2
  HeaderFlagRepoBlobCompressed* = 1'u32 shl 3
  ColdBlobBlockBytes* = 256
  ColdBlobHeaderBytes* = 12
  ColdBlobBlockHeaderBytes* = 4
  ColdBlobDecodeRingSize* = 4

type SourceSectionId* = enum
  ssNameOffsets
  ssNameLens
  ssNameBlob
  ssLowerOffsets
  ssLowerLens
  ssLowerBlob
  ssVersionOffsets
  ssVersionLens
  ssVersionBlob
  ssRepoIndices
  ssFlags
  ssRepoOffsets
  ssRepoLens
  ssRepoBlob
  ssBucketOffsets
  ssBucketLens
  ssBucketIds

type
  IndexedSourceKind* = enum
    iskSystem
    iskAur
    iskNimble

  IndexedPackageRecord* = object
    name*: string
    version*: string
    repo*: string
    installed*: bool

  SourceIndexStats* = object
    path*: string
    source*: IndexedSourceKind
    packageCount*: int
    repoCount*: int
    fileSize*: int

  ValidatedSourceIndex* = object
    error*: string
    path*: string
    packageCount*: int
    repoCount*: int
    sectionCount*: int
    fileSize*: int
    source*: IndexedSourceKind
    formatVersion*: int
    headerFlags*: int
    valid*: bool

  SourceSectionRange* = object
    offset*: int
    size*: int

  SourceIndexBuilder* = object
    source*: IndexedSourceKind
    repoMap*: OrderedTable[string, uint16]
    buckets*: array[BucketCount, seq[uint32]]
    repoOffsets*, repoLens*, repoIndices*, flags*: string
    nameOffsets*, nameLens*, lowerOffsets*, lowerLens*: string
    verOffsets*, verLens*: string
    nameBlob*, lowerBlob*, verBlob*, repoBlob*: string
    emittedCount*: int
    usesWideWords*: bool

  DecodedColdBlobBlock* = object
    valid*: bool
    blockIdx*: int32
    rawLen*: uint16
    data*: string

  CompressedBlobMeta* = object
    enabled*: bool
    rawLen*: int
    blockBytes*: int
    blockCount*: int
    offsetsStart*: int
    payloadStart*: int
    ringNext*: int
    ring*: seq[DecodedColdBlobBlock]

  SourceIndexView* = object
    path*: string
    file*: MemFile
    sections*: array[SourceSectionId, SourceSectionRange]
    packageCount*: int
    repoCount*: int
    sectionCount*: int
    fileSize*: int
    source*: IndexedSourceKind
    wordBytes*: int
    repoIndexBytes*: int
    headerFlags*: int
    versionBlobMeta*: CompressedBlobMeta
    repoBlobMeta*: CompressedBlobMeta
    mapped*: bool

  SectionPayload* = object
    name*: string
    data*: string

const SectionNames*: array[SourceSectionId, string] = [
  "name_off", "name_len", "name_blob", "lower_off", "lower_len", "lower_blob",
  "ver_off", "ver_len", "ver_blob", "repo_idx", "flags", "repo_off", "repo_len",
  "repo_blob", "bucket_off", "bucket_len", "bucket_ids",
]

type ColdDecodeStats* = object
  requests*: uint64
  hits*: uint64
  misses*: uint64
  decodedBlocks*: uint64
  decodedBytes*: uint64

proc sourceTag*(kind: IndexedSourceKind): string =
  case kind
  of iskSystem: "system"
  of iskAur: "aur"
  of iskNimble: "nimble"

proc findSectionId*(name: string): SourceSectionId =
  for section in SourceSectionId:
    if SectionNames[section] == name:
      return section
  raise newException(ValueError, "unknown source index section: " & name)
