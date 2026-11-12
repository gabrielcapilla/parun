import std/sets
import ../index/source_index_core
import ../index/source_index_runtime
import ../index/source_index_lazy

proc filterBySelectionBuffered*(
    selected: HashSet[string], view: ptr SourceIndexView, results: var seq[int32]
): string =
  results.setLen(0)
  if view.isNil or not valid(view):
    if not view.isNil and view[].proofError.len > 0:
      result = view[].proofError
    else:
      result = "source index is unavailable"
    return
  let repoError = ensureRepoSections(view)
  if repoError.len > 0:
    result = repoError
    return
  var key = newStringOfCap(64)
  let total = packageCount(view)
  for i in 0 ..< total:
    key.setLen(0)
    appendRepo(view, i, key)
    key.add('/')
    appendName(view, i, key)
    if key in selected:
      results.add(int32(i))
