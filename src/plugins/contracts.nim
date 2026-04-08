import ../core/types
import std/strutils

type
  PluginId* = enum
    PluginPacman
    PluginParu
    PluginYay
    PluginNimble

  PluginCapability* = enum
    capSearch
    capInstall
    capUninstall
    capDetails
    capSystemCatalog
    capAurCatalog
    capNimbleCatalog

  PluginContract* = object
    id*: PluginId
    key*: string
    bin*: string
    installCmd*: string
    uninstallCmd*: string
    searchCmd*: string
    sudo*: bool
    source*: DataSource
    capabilities*: set[PluginCapability]

func makeSystemPlugin(
    id: PluginId, key, bin: string, sudo: bool
): PluginContract {.inline.} =
  PluginContract(
    id: id,
    key: key,
    bin: bin,
    installCmd: " -S ",
    uninstallCmd: " -R ",
    searchCmd: " -Ss ",
    sudo: sudo,
    source: SourceSystem,
    capabilities:
      {capSearch, capInstall, capUninstall, capDetails, capSystemCatalog, capAurCatalog},
  )

func makeNimblePlugin(): PluginContract {.inline.} =
  PluginContract(
    id: PluginNimble,
    key: "nimble",
    bin: "nimble",
    installCmd: " install ",
    uninstallCmd: " uninstall ",
    searchCmd: " search ",
    sudo: false,
    source: SourceNimble,
    capabilities: {capSearch, capInstall, capUninstall, capDetails, capNimbleCatalog},
  )

const PluginContracts* = [
  PluginPacman: makeSystemPlugin(PluginPacman, "pacman", "pacman", true),
  PluginParu: makeSystemPlugin(PluginParu, "paru", "paru", false),
  PluginYay: makeSystemPlugin(PluginYay, "yay", "yay", false),
  PluginNimble: makeNimblePlugin(),
]

func getPluginContract*(id: PluginId): lent PluginContract {.inline.} =
  PluginContracts[id]

func supports*(plugin: PluginContract, capability: PluginCapability): bool {.inline.} =
  capability in plugin.capabilities

func hasCapabilities*(
    plugin: PluginContract, required: set[PluginCapability]
): bool {.inline.} =
  (required - plugin.capabilities).len == 0

func missingCapabilities*(
    plugin: PluginContract, required: set[PluginCapability]
): set[PluginCapability] {.inline.} =
  required - plugin.capabilities

func capabilityLabel*(capability: PluginCapability): string {.inline.} =
  case capability
  of capSearch: "search"
  of capInstall: "install"
  of capUninstall: "uninstall"
  of capDetails: "details"
  of capSystemCatalog: "system_catalog"
  of capAurCatalog: "aur_catalog"
  of capNimbleCatalog: "nimble_catalog"

proc capabilitySetLabel*(caps: set[PluginCapability]): string =
  var parts = newSeqOfCap[string](8)
  for cap in PluginCapability:
    if cap in caps:
      parts.add(capabilityLabel(cap))
  if parts.len == 0:
    return ""
  parts.join(",")

proc enforceCapabilities*(
    plugin: PluginContract, required: set[PluginCapability], context: string
) =
  let missing = plugin.missingCapabilities(required)
  if missing.len > 0:
    raise newException(
      ValueError,
      "plugin '" & plugin.key & "' missing capabilities for " & context & ": " &
        capabilitySetLabel(missing),
    )

static:
  for id in PluginId:
    let plugin = PluginContracts[id]
    doAssert(plugin.id == id, "plugin id mismatch for " & $id)
    doAssert(plugin.key.len > 0, "plugin key must not be empty")
    doAssert(plugin.bin.len > 0, "plugin bin must not be empty: " & plugin.key)
    doAssert(
      plugin.hasCapabilities({capSearch, capDetails}),
      "plugin missing base capabilities (search/details): " & plugin.key,
    )

    case plugin.source
    of SourceSystem:
      doAssert(
        plugin.hasCapabilities(
          {capInstall, capUninstall, capSystemCatalog, capAurCatalog}
        ),
        "system plugin missing required capabilities: " & plugin.key,
      )
      doAssert(
        plugin.installCmd.len > 0 and plugin.uninstallCmd.len > 0 and
          plugin.searchCmd.len > 0,
        "system plugin command template missing: " & plugin.key,
      )
      doAssert(
        capNimbleCatalog notin plugin.capabilities,
        "system plugin must not expose nimble catalog capability: " & plugin.key,
      )
    of SourceNimble:
      doAssert(
        plugin.hasCapabilities({capInstall, capUninstall, capNimbleCatalog}),
        "nimble plugin missing required capabilities: " & plugin.key,
      )
      doAssert(
        capSystemCatalog notin plugin.capabilities and
          capAurCatalog notin plugin.capabilities,
        "nimble plugin must not expose system/aur catalog capability: " & plugin.key,
      )
