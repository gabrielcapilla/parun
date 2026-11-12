import std/sets
import model
import ../index/indexes

proc packageSelectionKey*(view: ptr SourceIndexView, idx: int): string =
  if ensureRepoSections(view).len > 0:
    return ""
  result = copyRepo(view, idx)
  result.add("/")
  result.add(copyName(view, idx))

func isSelectedPackage*(selectedPackages: HashSet[string], key: string): bool =
  key in selectedPackages

proc isSelectedPackage*(state: AppState, view: ptr SourceIndexView, idx: int): bool =
  state.selectedPackages.isSelectedPackage(packageSelectionKey(view, idx))

proc toggleSelection*(state: var AppState, view: ptr SourceIndexView, idx: int) =
  let key = packageSelectionKey(view, idx)
  if key in state.selectedPackages:
    state.selectedPackages.excl(key)
  else:
    state.selectedPackages.incl(key)
