## Fixed-capacity per-frame string arena.
##
## Notes:
## - Used to avoid repeated small allocations during render/update cycles.
## - Allocation is bump-pointer with wrap-around, not general-purpose malloc.
import types

## Creates an arena with exact byte capacity.
proc initStringArena*(capacity: int): StringArena =
  var buffer = newSeqOfCap[char](capacity)
  buffer.setLen(capacity)
  StringArena(buffer: buffer, capacity: capacity, offset: 0)

proc allocString*(arena: var StringArena, s: string): StringArenaHandle =
  ## Copies `s` into arena and returns a stable slice handle until next reset/wrap.
  let requiredLen = s.len

  if requiredLen > arena.capacity:
    raise newException(
      IndexDefect,
      "String too large for arena: " & $requiredLen & " > " & $arena.capacity,
    )

  if arena.offset + requiredLen > arena.capacity:
    arena.offset = 0

  if arena.offset + requiredLen > arena.capacity:
    raise newException(IndexDefect, "Arena allocation failed after reset")

  if requiredLen > 0:
    copyMem(addr arena.buffer[arena.offset], unsafeAddr s[0], requiredLen)

  result = StringArenaHandle(startOffset: arena.offset, length: requiredLen)
  arena.offset += requiredLen

proc resetArena*(arena: var StringArena) =
  ## Resets bump pointer to start; existing handles become logically stale.
  arena.offset = 0
