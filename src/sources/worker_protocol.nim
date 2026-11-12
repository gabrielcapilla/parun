import ../catalog/model
import source_contracts

type
  WorkerReqKind* = enum
    ReqDetails
    ReqDiagnostics
    ReqStop

  WorkerReq* = object
    pkgName*, pkgRepo*, pkgUrl*: string
    pkgIdx*: int32

    detailGeneration*: uint64
    source*: DataSource
    pkgSlot*: SourceSlot
    kind*: WorkerReqKind

  PkgManagerType* = PluginId
  ToolDef* = PluginContract

  WorkerThreadArgs* = object
    reqChan*: ptr Channel[WorkerReq]
    resChan*: ptr Channel[Msg]
    toolType*: PkgManagerType

func getToolDef*(tool: PkgManagerType): lent ToolDef {.inline.} =
  getPluginContract(tool)
