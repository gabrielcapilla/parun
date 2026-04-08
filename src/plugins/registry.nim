import std/os
import ../core/types
import contracts

proc availableSystemPlugins*(): seq[PluginId] =
  result = newSeqOfCap[PluginId](3)
  if findExe("paru").len > 0:
    result.add(PluginParu)
  if findExe("yay").len > 0:
    result.add(PluginYay)
  result.add(PluginPacman)

proc detectSystemPlugin*(): PluginId =
  availableSystemPlugins()[0]

func pluginForSource*(source: DataSource, systemPlugin: PluginId): PluginId {.inline.} =
  if source == SourceNimble: PluginNimble else: systemPlugin
