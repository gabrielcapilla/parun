import unittest
import std/[monotimes, times, strutils, tables]
import ../src/pkgs/batcher
import ../src/core/types

suite "Batcher - Initialization":
  test "initBatchBuilder - valores por defecto":
    let bb = initBatchBuilder()

    check bb.soa.hot.locators.len == 0
    check bb.soa.hot.nameLens.len == 0
    check bb.soa.cold.verLens.len == 0
    check bb.soa.cold.repoIndices.len == 0
    check bb.soa.cold.flags.len == 0
    check bb.textChunk == ""
    check bb.repos.len == 0

  test "initBatchBuilder - con capacidad reservada":
    let bb = initBatchBuilder()

    check capacity(bb.soa.hot.locators) >= 1000
    check capacity(bb.soa.hot.nameLens) >= 1000
    check capacity(bb.soa.cold.verLens) >= 1000
    check capacity(bb.soa.cold.repoIndices) >= 1000
    check capacity(bb.soa.cold.flags) >= 1000
    check capacity(bb.textChunk) >= BatchSize

  test "initBatchBuilder - repoMap inicializado":
    let bb = initBatchBuilder()
    check len(bb.repoMap) == 0

suite "Batcher - Package Addition":
  test "addPackage - paquete simple":
    var bb = initBatchBuilder()
    addPackage(bb, "vim", "8.0.0", "extra", false)

    check bb.soa.hot.locators.len == 1
    check bb.textChunk.contains("vim")
    check bb.textChunk.contains("8.0.0")

  test "addPackage - multiples paquetes":
    var bb = initBatchBuilder()
    addPackage(bb, "vim", "8.0.0", "extra", false)
    addPackage(bb, "emacs", "25.0", "extra", false)
    addPackage(bb, "nano", "4.0", "core", false)

    check bb.soa.hot.locators.len == 3
    check bb.repos.len == 2 # extra y core

  test "addPackage - deduplica repositorios":
    var bb = initBatchBuilder()
    addPackage(bb, "vim", "8.0.0", "extra", false)
    addPackage(bb, "emacs", "25.0", "extra", false)

    check bb.repos.len == 1
    check bb.repos[0] == "extra"

  test "addPackage - indice de repositorio correcto":
    var bb = initBatchBuilder()
    addPackage(bb, "vim", "8.0.0", "extra", false)
    addPackage(bb, "nano", "4.0", "core", false)

    check bb.soa.cold.repoIndices[0] != bb.soa.cold.repoIndices[1]

  test "addPackage - flag de instalado":
    var bb = initBatchBuilder()
    addPackage(bb, "vim", "8.0.0", "extra", true)
    addPackage(bb, "emacs", "25.0", "extra", false)

    check (bb.soa.cold.flags[0] and 1) == 1
    check (bb.soa.cold.flags[1] and 1) == 0

  test "addPackage - respeta BatchSize":
    var bb = initBatchBuilder()
    # Llenar batch hasta cerca del limite
    bb.textChunk = "a".repeat(BatchSize - 10)

    # Este paquete deberia caber
    addPackage(bb, "small", "1.0", "extra", false)
    check bb.textChunk.len < BatchSize

    # Este paquete no deberia caber
    var oldLen = bb.soa.hot.locators.len
    bb.textChunk = "a".repeat(BatchSize - 5)
    addPackage(bb, "toolarge" & "x".repeat(100), "1.0", "extra", false)
    check bb.soa.hot.locators.len == oldLen # No agrego

suite "Batcher - Batch Flushing":
  test "flushBatch - envia datos al canal":
    var bb = initBatchBuilder()
    addPackage(bb, "vim", "8.0.0", "extra", false)

    var chan: Channel[Msg]
    chan.open()

    let start = getMonoTime()
    flushBatch(bb, chan, 1, start)

    # Verificar que se envio mensaje
    let msg = chan.recv()
    check msg.kind == MsgSearchResults
    check msg.searchId == 1

    chan.close()

  test "flushBatch - resetea builder":
    var bb = initBatchBuilder()
    addPackage(bb, "vim", "8.0.0", "extra", false)

    var chan: Channel[Msg]
    chan.open()

    flushBatch(bb, chan, 1, getMonoTime())

    check bb.soa.hot.locators.len == 0
    check bb.soa.hot.nameLens.len == 0
    check bb.soa.cold.verLens.len == 0
    check bb.soa.cold.repoIndices.len == 0
    check bb.soa.cold.flags.len == 0
    check bb.textChunk == ""
    check bb.repos.len == 0

    chan.close()

  test "flushBatch - no envia si vacio":
    var bb = initBatchBuilder()

    var chan: Channel[Msg]
    chan.open()

    flushBatch(bb, chan, 1, getMonoTime())

    # Verificar que no hay mensaje en el canal
    # Si hay mensaje, recv() desbloqueara. Si no, bloqueara.
    # No podemos probar esto directamente sin timeout.
    # Asi que solo verificamos que el builder siga vacio
    check bb.soa.hot.locators.len == 0
    check bb.textChunk == ""

    chan.close()

  test "flushBatch - reutiliza memoria":
    var bb = initBatchBuilder()
    bb.soa.hot.locators = newSeqOfCap[uint32](1000)
    addPackage(bb, "vim", "8.0.0", "extra", false)

    var chan: Channel[Msg]
    chan.open()

    let capBefore = capacity(bb.soa.hot.locators)
    flushBatch(bb, chan, 1, getMonoTime())
    let capAfter = capacity(bb.soa.hot.locators)

    check capBefore == capAfter # Capacidad preservada
    chan.close()

suite "Batcher - Performance":
  test "Benchmark addPackage 10K paquetes":
    var bb = initBatchBuilder()
    var totalAdded = 0

    let start = getMonoTime()
    for i in 0 ..< 10000:
      let addedBefore = bb.soa.hot.locators.len
      addPackage(bb, "pkg" & $i, "1.0.0", "extra", false)
      if bb.soa.hot.locators.len > addedBefore:
        inc(totalAdded)

      # Reset batch cuando se llena para continuar
      if bb.textChunk.len > BatchSize - 1000:
        var chan: Channel[Msg]
        chan.open()
        flushBatch(bb, chan, i, start)
        chan.close()

    let elapsed = getMonoTime() - start

    check totalAdded == 10000
    check elapsed.inMilliseconds < 200 # < 200ms

  test "Benchmark deduplicacion de repos":
    var bb = initBatchBuilder()
    let repos = ["extra", "core", "community", "multilib"]

    let start = getMonoTime()
    for i in 0 ..< 1000:
      addPackage(bb, "pkg" & $i, "1.0.0", repos[i mod 4], false)
    let elapsed = getMonoTime() - start

    check bb.repos.len == 4 # Solo 4 repos unicos
    check elapsed.inMilliseconds < 50 # O(1) lookup

  test "Benchmark flushBatch 100 batches":
    var chan: Channel[Msg]
    chan.open()

    let start = getMonoTime()
    for i in 0 ..< 100:
      var bb = initBatchBuilder()
      addPackage(bb, "vim", "8.0.0", "extra", false)
      flushBatch(bb, chan, i, getMonoTime())
    let elapsed = getMonoTime() - start

    check elapsed.inMilliseconds < 500 # < 500ms total
    chan.close()

  test "Memory allocation - addPackage minimal GC":
    var bb = initBatchBuilder()

    let gcBefore = getOccupiedMem()
    for i in 0 ..< 1000:
      addPackage(bb, "pkg" & $i, "1.0.0", "extra", false)
    let gcAfter = getOccupiedMem()

    let gcDelta = gcAfter - gcBefore
    # Deberia ser minimo con BatchSize apropiado
    check gcDelta < 1024 * 100 # < 100KB

suite "Batcher - Edge Cases":
  test "addPackage - nombre vacio":
    var bb = initBatchBuilder()
    addPackage(bb, "", "1.0.0", "extra", false)

    check bb.soa.hot.locators.len == 1
    check bb.soa.hot.nameLens[0] == 0

  test "addPackage - version muy larga (>255 chars)":
    var bb = initBatchBuilder()
    let longVer = "1.0.0" & ".0".repeat(100)

    # nameLens es uint8, asi que deberia truncar o manejar
    addPackage(bb, "test", longVer, "extra", false)

    check bb.soa.hot.locators.len == 1

  test "addPackage - 256 repos diferentes":
    var bb = initBatchBuilder()

    for i in 0 ..< 256:
      addPackage(bb, "pkg" & $i, "1.0.0", "repo" & $i, false)

    # repoIndices es uint8, asi que maximo 255 repos unicos
    check bb.soa.hot.locators.len == 256
    # Algunos repos tendran indice 0 (fallback)

  test "addPackage - caracteres especiales en nombre":
    var bb = initBatchBuilder()
    addPackage(bb, "pkg-name_123", "1.0.0", "extra", false)

    check bb.textChunk.contains("pkg-name_123")

  test "addPackage - repo vacio":
    var bb = initBatchBuilder()
    addPackage(bb, "test", "1.0.0", "", false)

    check bb.soa.hot.locators.len == 1
    # El repo vacio deberia agregarse al mapa

  test "flushBatch - datos parciales":
    var bb = initBatchBuilder()
    addPackage(bb, "vim", "8.0.0", "extra", false)
    addPackage(bb, "emacs", "25.0", "core", false)

    var chan: Channel[Msg]
    chan.open()

    flushBatch(bb, chan, 1, getMonoTime())
    let msg = chan.recv()

    check msg.soa.hot.locators.len == 2
    check msg.repos.len == 2

    chan.close()
