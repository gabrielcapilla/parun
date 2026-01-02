import unittest
import std/[monotimes, times, random]
import ../src/utils/simd
import ../src/core/types

suite "SIMD - prepareSearchContext":
  test "Query vacío":
    let ctx = prepareSearchContext("")
    check ctx.isValid == false

  test "Query solo espacios":
    let ctx = prepareSearchContext("   ")
    check ctx.isValid == false

  test "Query simple palabra":
    let ctx = prepareSearchContext("vim")
    check ctx.isValid == true
    check ctx.tokens == @["vim"]
    check ctx.lowerTokens == @["vim"]

  test "Query múltiples palabras":
    let ctx = prepareSearchContext("vim editor")
    check ctx.isValid == true
    check ctx.tokens == @["vim", "editor"]
    check ctx.lowerTokens == @["vim", "editor"]

  test "Query con mayúsculas":
    let ctx = prepareSearchContext("VIM Editor")
    check ctx.lowerTokens == @["vim", "editor"]

  test "Query con caracteres especiales":
    let ctx = prepareSearchContext("vim++ editor-2.0")
    check ctx.tokens == @["vim++", "editor-2.0"]

  test "Número de tokens vs firstCharVecs":
    let ctx = prepareSearchContext("a b c d e")
    check ctx.tokens.len == 5
    check ctx.firstCharVecs.len == 5

suite "SIMD - scorePackageSimd":
  setup:
    var buf = newString(256)
    buf.setLen(256)
    let ptrBuf = cast[ptr char](addr buf[0])

  test "Match exacto al inicio - score máximo":
    buf.setLen(256)
    buf[0] = 'v'
    buf[1] = 'i'
    buf[2] = 'm'
    let ctx = prepareSearchContext("vim")
    let score = scorePackageSimd(ptrBuf, 3, ctx)
    check score > 140

  test "Match exacto en el medio":
    buf.setLen(256)
    buf[0 .. 12] = "neovim-editor"
    let ctx = prepareSearchContext("vim")
    let score = scorePackageSimd(ptrBuf, 13, ctx)
    check score >= 100

  test "Match después de separador":
    buf.setLen(256)
    buf[0 .. 5] = "neovim"
    let ctx = prepareSearchContext("vim")
    let score = scorePackageSimd(ptrBuf, 6, ctx)
    check score > 140

  test "No match - score 0":
    buf.setLen(256)
    buf[0 .. 4] = "emacs"
    let ctx = prepareSearchContext("vim")
    let score = scorePackageSimd(ptrBuf, 5, ctx)
    check score == 0

  test "Query más largo que texto":
    buf.setLen(256)
    buf[0 .. 2] = "vim"
    let ctx = prepareSearchContext("vim-editor")
    let score = scorePackageSimd(ptrBuf, 3, ctx)
    check score == 0

  test "Mayúsculas/Minúsculas insensibles":
    buf.setLen(256)
    buf[0 .. 2] = "VIM"
    let ctx = prepareSearchContext("vim")
    let score = scorePackageSimd(ptrBuf, 3, ctx)
    check score > 140

  test "Texto vacío":
    let ctx = prepareSearchContext("vim")
    let score = scorePackageSimd(ptrBuf, 0, ctx)
    check score == 0

  test "Context inválido":
    let ctx = prepareSearchContext("")
    let score = scorePackageSimd(ptrBuf, 10, ctx)
    check score == 0

suite "SIMD - countingSortResults":
  test "Buffer vacío":
    var buf: ResultsBuffer
    buf.count = 0
    countingSortResults(buf)
    check buf.count == 0

  test "Orden ascendente - ya ordenado":
    var buf: ResultsBuffer
    buf.count = 3
    buf.indices[0] = int32(0)
    buf.indices[1] = int32(1)
    buf.indices[2] = int32(2)
    buf.scores[0] = 100
    buf.scores[1] = 200
    buf.scores[2] = 300
    countingSortResults(buf)
    check buf.scores[0] == 300
    check buf.scores[1] == 200
    check buf.scores[2] == 100

  test "Orden descendente - inversión":
    var buf: ResultsBuffer
    buf.count = 3
    buf.indices[0] = int32(0)
    buf.indices[1] = int32(1)
    buf.indices[2] = int32(2)
    buf.scores[0] = 300
    buf.scores[1] = 200
    buf.scores[2] = 100
    countingSortResults(buf)
    check buf.scores[0] == 300
    check buf.scores[1] == 200
    check buf.scores[2] == 100

  test "Orden aleatorio":
    var buf: ResultsBuffer
    buf.count = 5
    buf.indices[0] = int32(3)
    buf.indices[1] = int32(1)
    buf.indices[2] = int32(4)
    buf.indices[3] = int32(0)
    buf.indices[4] = int32(2)
    buf.scores[0] = 150
    buf.scores[1] = 300
    buf.scores[2] = 50
    buf.scores[3] = 200
    buf.scores[4] = 100
    countingSortResults(buf)
    check buf.scores[0] == 300
    check buf.scores[1] == 200
    check buf.scores[2] == 150
    check buf.scores[3] == 100
    check buf.scores[4] == 50

suite "SIMD - Fuzzing":
  test "Random strings - no crashes":
    for i in 0 ..< 100:
      let len = rand(255) + 1
      var s = newString(len)
      for j in 0 ..< len:
        s[j] = char(rand(255))
      let ptrS = cast[ptr char](addr s[0])

      let ctx = prepareSearchContext("test")
      if s.len > 0 and ctx.isValid:
        discard scorePackageSimd(ptrS, len, ctx)
      check true

suite "SIMD - Performance Benchmarks":
  test "Benchmark scorePackageSimd 100K iteraciones":
    var buf = newString(256)
    buf.setLen(256)
    let ptrBuf = cast[ptr char](addr buf[0])
    buf[0 .. 28] = "example-package-name-for-testing"

    let ctx = prepareSearchContext("example")

    let start = getMonoTime()
    for i in 0 ..< 100_000:
      discard scorePackageSimd(ptrBuf, 29, ctx)
    let elapsed = getMonoTime() - start

    check elapsed.inMilliseconds < 100

  test "Benchmark countingSortResults 2000 elementos":
    var buf: ResultsBuffer
    buf.count = 2000
    for i in 0 ..< 2000:
      buf.indices[i] = int32(i)
      buf.scores[i] = rand(999)

    let start = getMonoTime()
    countingSortResults(buf)
    let elapsed = getMonoTime() - start

    check elapsed.inMilliseconds < 1

  test "Benchmark prepareSearchContext 10K queries":
    let queries = ["vim", "emacs", "nano", "editor", "terminal"]
    let start = getMonoTime()
    for i in 0 ..< 10_000:
      let q = queries[i mod queries.len]
      discard prepareSearchContext(q)
    let elapsed = getMonoTime() - start

    check elapsed.inMilliseconds < 50
