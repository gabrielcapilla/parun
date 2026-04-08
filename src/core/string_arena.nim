import types

proc initStringArena*(capacity: int): StringArena =
  var buffer = newSeqOfCap[char](capacity)
  buffer.setLen(capacity)
  StringArena(buffer: buffer, capacity: capacity, offset: 0)

proc allocString*(arena: var StringArena, s: string): StringArenaHandle =
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
  arena.offset = 0
