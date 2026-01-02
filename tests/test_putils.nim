import unittest
import std/[monotimes, times, strutils, tables]
import ../src/utils/pUtils

suite "pUtils - parseInstalledPackages":
  test "Salida pacman -Q estandar":
    let output =
      """
pacman 6.0.2-2
linux-firmware 20241119.6d0ed8e-1
"""
    let result = parseInstalledPackages(output)
    check len(result) == 2
    check result["pacman"] == "6.0.2-2"
    check result["linux-firmware"] == "20241119.6d0ed8e-1"

  test "Salida con lineas vacias":
    let output =
      """

pacman 6.0.2-2

linux-firmware 20241119.6d0ed8e-1

"""
    let result = parseInstalledPackages(output)
    check len(result) == 2

  test "Linea incompleta (solo nombre)":
    let output =
      """
pacman
linux-firmware 1.0.0
"""
    let result = parseInstalledPackages(output)
    check len(result) == 1
    check "linux-firmware" in result

  test "Salida vacia":
    let result = parseInstalledPackages("")
    check len(result) == 0

  test "Paquete con multiples espacios":
    let output = "package-name    1.0.0-1"
    let result = parseInstalledPackages(output)
    # split(' ') crea multiples strings vacios
    # La funcion solo guarda si parts.len > 1
    # Asi que solo guarda "package-name" -> "" y despues "" -> "1.0.0-1"
    # El resultado final depende del orden de iteracion
    check len(result) == 1

  test "Version con guiones y puntos":
    let output = "complex-pkg 2.1.0-beta.3+20241201-1"
    let result = parseInstalledPackages(output)
    check result["complex-pkg"] == "2.1.0-beta.3+20241201-1"

suite "pUtils - isPackageInstalled":
  test "Marcador [installed] en ingles":
    check isPackageInstalled("core pacman 6.0.2-2 [installed]") == true

  test "Marcador [instalado] en espanol":
    check isPackageInstalled("core pacman 6.0.2-2 [instalado]") == true

  test "Sin marcador":
    check isPackageInstalled("core pacman 6.0.2-2") == false

  test "Marcador al final":
    check isPackageInstalled("extra gcc 14.2.1+20241130-1 [installed]") == true

  test "Caso extremo - multiples corchetes":
    check isPackageInstalled("extra pkg[brackets] 1.0.0 [installed]") == true

  test "Caso extremo - corchetes en nombre":
    # La funcion solo busca [installed] o [instalado]
    # [bracketed] no es un marcador valido de instalacion
    check isPackageInstalled("extra pkg[brackets] 1.0.0 [bracketed]") == false

  test "Linea vacia":
    check isPackageInstalled("") == false

  test "Solo marcador":
    check isPackageInstalled("[installed]") == true

suite "pUtils - Performance":
  test "Benchmark parseInstalledPackages 10K paquetes":
    var output = ""
    for i in 0 ..< 10000:
      output &= "pkg" & $i & " " & $i & ".0.0-1\n"
    let start = getMonoTime()
    let result = parseInstalledPackages(output)
    let elapsed = getMonoTime() - start
    check len(result) == 10000
    check elapsed.inMilliseconds < 100 # Debe ser < 100ms
