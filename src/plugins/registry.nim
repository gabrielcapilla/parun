## Runtime plugin selection policy.
##
## Priority for system source is `paru -> yay -> pacman`.
import std/os
import ../core/types
import contracts

proc availableSystemPlugins*(): seq[PluginId] =
  ## Lists available system plugins in preferred order.
  result = newSeqOfCap[PluginId](3)
  if findExe("paru").len > 0:
    result.add(PluginParu)
  if findExe("yay").len > 0:
    result.add(PluginYay)
  result.add(PluginPacman)

proc detectSystemPlugin*(): PluginId =
  ## Picks the first available system plugin.
  availableSystemPlugins()[0]

func pluginForSource*(source: DataSource, systemPlugin: PluginId): PluginId {.inline.} =
  ## Maps logical source to concrete plugin id.
  if source == SourceNimble: PluginNimble else: systemPlugin
