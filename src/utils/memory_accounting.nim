## Generic memory-accounting helpers used by worker diagnostics.
##
## Notes:
## - `nestedBytes` estimates owned heap capacity, not serialized payload size.
## - Table sizing uses a mirror type to inspect internal seq capacity.
import std/[hashes, tables]

type
  MemoryMetric* = object
    name*: string
    bytes*: int
    length*: int
    capacity*: int
    note*: string

  MemorySection* = object
    name*: string
    metrics*: seq[MemoryMetric]

  WorkerMemoryReport* = object
    sections*: seq[MemorySection]

  TableEntry[K, V] = tuple[hcode: Hash, key: K, val: V]
  TableMirror[K, V] = object
    data: seq[TableEntry[K, V]]
    counter: int

proc metric*(
    name: string, bytes: int, length: int = 0, capacity: int = 0, note: string = ""
): MemoryMetric {.inline.} =
  ## Constructs one metric row.
  MemoryMetric(name: name, bytes: bytes, length: length, capacity: capacity, note: note)

proc addMetric*(
    section: var MemorySection,
    name: string,
    bytes: int,
    length: int = 0,
    capacity: int = 0,
    note: string = "",
) {.inline.} =
  section.metrics.add(metric(name, bytes, length, capacity, note))

proc nestedBytes*(value: string): int {.inline.} =
  capacity(value)

proc nestedBytes*[T: SomeInteger | SomeFloat | char | bool | enum](
    value: T
): int {.inline.} =
  0

proc nestedBytes*[T](value: seq[T]): int =
  result = capacity(value) * sizeof(T)
  for item in value:
    result += nestedBytes(item)

proc nestedBytes*[T: tuple](value: T): int =
  for _, field in fieldPairs(value):
    result += nestedBytes(field)

proc nestedBytes*[T: object](value: T): int =
  for _, field in fieldPairs(value):
    result += nestedBytes(field)

proc nestedBytes*[K, V](value: Table[K, V]): int =
  let mirror = cast[ptr TableMirror[K, V]](unsafeAddr value)
  result = capacity(mirror[].data) * sizeof(TableEntry[K, V])
  for key, item in value.pairs:
    result += nestedBytes(key)
    result += nestedBytes(item)

proc addStringMetric*(
    section: var MemorySection, name: string, value: string, note: string = ""
) =
  section.addMetric(name, nestedBytes(value), value.len, capacity(value), note)

proc addSeqMetric*[T](
    section: var MemorySection, name: string, value: seq[T], note: string = ""
) =
  section.addMetric(name, nestedBytes(value), value.len, capacity(value), note)

proc addTableMetric*[K, V](
    section: var MemorySection, name: string, value: Table[K, V], note: string = ""
) =
  let mirror = cast[ptr TableMirror[K, V]](unsafeAddr value)
  section.addMetric(name, nestedBytes(value), value.len, capacity(mirror[].data), note)

proc addScalarMetric*(
    section: var MemorySection, name: string, bytes: int, note: string = ""
) =
  section.addMetric(name, bytes, note = note)

proc sectionBytes*(section: MemorySection): int =
  ## Aggregates bytes for one section.
  for item in section.metrics:
    result += item.bytes

proc reportBytes*(report: WorkerMemoryReport): int =
  ## Aggregates bytes across all sections.
  for section in report.sections:
    result += section.sectionBytes()
