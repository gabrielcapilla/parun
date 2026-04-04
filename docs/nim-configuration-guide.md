# Nim Configuration Files: nim.cfg vs config.nims

## Resumen Ejecutivo (Enero 2026)

**Estado actual:** Ambos formatos son soportados oficialmente en Nim 2.2.6. No hay deprecación planificada para nim.cfg.

**Recomendación:** Usa **config.nims** para proyectos nuevos por mayor flexibilidad y poder. Mantén nim.cfg para compatibilidad o configuraciones simples.

---

## Tabla Comparativa

| Característica | nim.cfg | config.nims |
|----------------|---------|-------------|
| **Formato** | Archivo de configuración estilo INI | NimScript (código Nim ejecutable) |
| **Extensión** | `.cfg` | `.nims` |
| **Sintaxis** | `clave = valor` | Código Nim completo |
| **Lógica condicional** | ❌ No soportada | ✅ Soportada (if, case, etc.) |
| **Variables** | ❌ No soportadas | ✅ Soportadas |
| **Funciones/Procs** | ❌ No soportadas | ✅ Soportadas |
| **Tareas (tasks)** | ❌ No soportadas | ✅ Soportadas |
| **Complejidad** | Simple, declarativo | Avanzado, programático |
| **Curva de aprendizaje** | Baja | Media (requiere conocer Nim) |
| **Potencia** | Limitada | Ilimitada |
| **Módulos stdlib** | Ninguno | ~30 módulos disponibles |

---

## Ubicaciones de Archivos de Configuración

### Orden de Procesamiento (de menor a mayor prioridad)

Los archivos se procesan en este orden, y los posteriores sobrescriben a los anteriores:

#### 1. Configuración Global
- **nim.cfg:** `$nim/config/nim.cfg` o `/etc/nim/nim.cfg` (Unix) / `<Nim install>\config\nim.cfg` (Windows)
- **config.nims:** No aplica (no hay config.nims global)
- **Skip:** `--skipCfg`

#### 2. Configuración de Usuario
- **nim.cfg:** `$XDG_CONFIG_HOME/nim/nim.cfg` o `~/.config/nim/nim.cfg` (POSIX) / `%APPDATA%/nim/nim.cfg` (Windows)
- **config.nims:** `$XDG_CONFIG_HOME/nim/config.nims` o `~/.config/nim/config.nims` (POSIX) / `%APPDATA%/nim/config.nims` (Windows)
- **Skip:** `--skipUserCfg`

#### 3. Directorios Padre
- **nim.cfg:** `$parentDir/nim.cfg` (cualquier directorio padre del proyecto)
- **config.nims:** `$parentDir/config.nims`
- **Skip:** `--skipParentCfg`

#### 4. Directorio del Proyecto
- **nim.cfg:** `$projectDir/nim.cfg`
- **config.nims:** `$projectDir/config.nims`
- **Skip:** `--skipProjCfg`

#### 5. Archivo Específico
- **nim.cfg:** `$project.nim.cfg` (mismo directorio que `$project.nim`)
- **config.nims:** `$project.nims` (mismo directorio que `$project.nim`)
- **Skip:** `--skipProjCfg`

**Nota importante:** Los archivos .nims tienen **mayor prioridad** que los .cfg en la misma ubicación.

---

## Sintaxis de nim.cfg

### Formato Básico

```cfg
# Comentario
clave = valor

# Flags del compilador
--opt:size
--define:release
--threads:on

# Pasar opciones al compilador C
--passC:"-flto"
--passL:"-s"

# Configuración específica por backend
amd64.windows.gcc.path = "/usr/bin"
arm.linux.gcc.exe = "arm-linux-gcc"
```

### Variables de Sustitución

- `$nim`: Prefijo global de Nim
- `$lib`: Path de la stdlib
- `$home` o `~`: Home del usuario
- `$config`: Directorio del módulo siendo compilado
- `$projectname`: Nombre del archivo de proyecto (sin extensión)
- `$projectpath` o `$projectdir`: Path del archivo de proyecto
- `$nimcache`: Path del nimcache

---

## Sintaxis de config.nims

### Formato Básico

```nim
# Usando la función switch()
switch("opt", "size")
switch("define", "release")
switch("threads", "on")

# Usando la sintaxis abreviada -- (más común)
--opt:size
--define:release
--threads:on
--passC:"-flto"
--passL:"-s"
```

### Lógica Condicional

```nim
import std/distros

# Detectar sistema operativo
if defined(linux):
  --passL:"-lm"
elif defined(windows):
  --app:gui
  --passL:"-lws2_32"

# Detectar distribución Linux
if detectOs(ArchLinux):
  --passC:"-march=native"
elif detectOs(Ubuntu):
  --passC:"-mtune=generic"

# Detectar arquitectura
if defined(amd64):
  --define:sse2
elif defined(arm):
  --define:arm_neon
```

### Variables y Funciones

```nim
let projectName = "myproject"
let version = "1.0.0"

proc setupReleaseBuild() =
  --define:release
  --opt:speed
  --passC:"-flto"
  --passL:"-s"
  --strip

# Condicional basado en modo
if defined(release):
  setupReleaseBuild()
else:
  --debugger:native
  --stackTrace:on
  --lineTrace:on
```

### Definición de Tareas

```nim
task build, "Build the project":
  setCommand "c"
  --define:release
  --opt:speed

task test, "Run tests":
  setCommand "c"
  --run
  --path:"tests"
  exec "nim c -r tests/test_all.nim"

task clean, "Clean build artifacts":
  rmDir "nimcache"
  rmFile "myproject"

task bench, "Run benchmarks":
  --define:release
  --opt:speed
  setCommand "c"
  exec "nim c -r benchmarks/bench.nim"
```

---

## Módulos Stdlib Disponibles en NimScript

NimScript (config.nims) soporta los siguientes módulos de la stdlib:

- **algorithm**
- **base64**
- **bitops**
- **chains**
- **colors**
- **complex**
- **distros** (detección de OS/distribución)
- **std/editdistance**
- **htmlgen**
- **htmlparser**
- **httpcore**
- **json**
- **lenientops**
- **macros**
- **math**
- **options**
- **os** (operaciones de sistema de archivos)
- **parsecfg**
- **parsecsv**
- **parsejson**
- **parsesql**
- **parseutils**
- **punycode**
- **random**
- **ropes**
- **std/setutils**
- **stats**
- **strformat**
- **strmisc**
- **strscans**
- **strtabs**
- **strutils**
- **sugar**
- **unicode**
- **unidecode**
- **uri**
- **std/wordwrap**
- **xmlparser**

### Módulo nimscript

Además, NimScript incluye el módulo `nimscript` que proporciona funciones específicas:

```nim
# Funciones disponibles
switch("clave", "valor")     # Establecer flag del compilador
--clave:valor                # Sintaxis abreviada
setCommand("c")              # Establecer comando (c, cpp, js, etc.)
task nombre, "descripción":   # Definir tarea
  # código de la tarea
exec("comando")              # Ejecutar comando del sistema
withDir("ruta"):             # Cambiar directorio temporalmente
  # código
rmDir("ruta")                # Eliminar directorio
rmFile("archivo")            # Eliminar archivo
mvFile("orig", "dest")       # Mover archivo
cpFile("orig", "dest")       # Copiar archivo
```

---

## Limitaciones de NimScript

NimScript tiene algunas limitaciones debido a que se ejecuta en una VM:

1. **FFI (Foreign Function Interface):** No disponible. No se pueden usar módulos que dependan de `importc`.
2. **Operaciones con punteros:** Disponibles pero pueden tener bugs en casos edge.
3. **Argumentos var T:** Pueden ser problemáticos en algunos casos.
4. **Múltiples niveles de ref:** No soportados (ej: `ref ref int`).
5. **Multimethods:** No disponibles.
6. **Algunos defines especiales:** `-d:strip`, `-d:lto`, `-d:lto_incremental` no pueden establecerse en NimScript.

---

## Casos de Uso y Ejemplos

### Caso 1: Configuración Simple (usar nim.cfg)

Para proyectos simples sin lógica condicional compleja:

**nim.cfg:**
```cfg
--threads:on
--mm:orc
--define:ssl
--opt:speed
```

### Caso 2: Configuración Multiplataforma (usar config.nims)

Para proyectos que necesitan comportamiento diferente según la plataforma:

**config.nims:**
```nim
import std/distros

# Configuración base
--threads:on
--mm:orc

# Configuración específica por plataforma
if defined(windows):
  --app:console
  --passL:"-lws2_32"
elif defined(linux):
  --passL:"-lm -lpthread"
  if detectOs(ArchLinux):
    --passC:"-march=native"
  else:
    --passC:"-mtune=generic"
elif defined(macosx):
  --passL:"-framework CoreFoundation"
```

### Caso 3: Build System Completo (usar config.nims)

Para proyectos que necesitan tareas de build complejas:

**config.nims:**
```nim
import std/os

# Configuración por defecto
--threads:on
--mm:orc

# Tarea de build para release
task release, "Build optimized release":
  --define:release
  --opt:speed
  --passC:"-flto"
  --passL:"-s"
  --strip
  --lto
  setCommand "c"

# Tarea de build para debug
task debug, "Build debug version":
  --debugger:native
  --stackTrace:on
  --lineTrace:on
  --checks:on
  setCommand "c"

# Tarea para correr tests
task test, "Run all tests":
  --path:"tests"
  --run
  setCommand "c"
  for testFile in walkFiles("tests/test_*.nim"):
    exec "nim c -r " & testFile

# Tarea para limpiar
task clean, "Clean build artifacts":
  rmDir "nimcache"
  rmDir "bin"
  for f in walkFiles("*.exe"):
    rmFile(f)
```

### Caso 4: Configuración con Variables de Entorno

**config.nims:**
```nim
import std/os

# Leer variables de entorno
let buildType = getEnv("BUILD_TYPE", "debug")
let enableSsl = getEnv("ENABLE_SSL", "true")

if enableSsl == "true":
  --define:ssl

if buildType == "release":
  --define:release
  --opt:speed
  --strip
else:
  --debugger:native
  --stackTrace:on
```

---

## Mejores Prácticas

### 1. Para Proyectos Nuevos

**Recomendación:** Usa `config.nims` desde el inicio.

```nim
# config.nims - Configuración moderna y flexible
import std/distros

--threads:on
--mm:orc

if defined(release):
  --opt:speed
  --strip
  --lto
else:
  --debugger:native
  --checks:on
```

### 2. Para Proyectos Legado

**Recomendación:** Mantén `nim.cfg` si funciona, migra a `config.nims` solo si necesitas nuevas funcionalidades.

### 3. Convenciones de Nombres

- **Archivo principal:** `config.nims` (recomendado) o `nim.cfg`
- **Archivo específico:** `$project.nims` o `$project.nim.cfg`
- **No mezclar:** Evita tener ambos `nim.cfg` y `config.nims` en el mismo directorio (puede causar confusión)

### 4. Documentación

Siempre documenta tu configuración:

```nim
# config.nims
# Configuración de build para Proyecto X
# 
# Uso:
#   nim build          # Build por defecto (debug)
#   nim release        # Build optimizado
#   nim test           # Correr tests
#
# Variables de entorno:
#   BUILD_TYPE=release # Fuerza build de release

import std/[os, distros]

# ... configuración ...
```

---

## Migración de nim.cfg a config.nims

### Ejemplo de Migración

**Antes (nim.cfg):**
```cfg
--threads:on
--mm:orc
--define:ssl
--opt:speed
--passC:"-flto"
--passL:"-s"
```

**Después (config.nims):**
```nim
--threads:on
--mm:orc
--define:ssl
--opt:speed
--passC:"-flto"
--passL:"-s"
```

### Migración con Lógica Condicional

**Antes (nim.cfg - limitado):**
```cfg
# No se puede hacer lógica condicional
--threads:on
```

**Después (config.nims - flexible):**
```nim
import std/distros

--threads:on

if defined(linux) and detectOs(ArchLinux):
  --passC:"-march=native"
```

---

## Referencias Oficiales

- **Nim Compiler User Guide:** https://nim-lang.org/docs/nimc.html
- **NimScript Documentation:** https://nim-lang.org/docs/nims.html
- **Nim Manual:** https://nim-lang.org/docs/manual.html
- **NimScript Module:** https://nim-lang.org/docs/nimscript.html
- **Distros Module:** https://nim-lang.org/docs/distros.html

---

## Versión de Documentación

- **Fecha:** Enero 2026
- **Versión de Nim:** 2.2.6
- **Estado:** Información actualizada y verificada

---

## Notas Importantes

1. **No hay deprecación:** nim.cfg sigue siendo soportado oficialmente y no hay planes de eliminarlo.

2. **Prioridad:** config.nims tiene mayor prioridad que nim.cfg en la misma ubicación.

3. **Compatibilidad:** Los proyectos pueden usar ambos formatos simultáneamente en diferentes niveles (ej: nim.cfg global + config.nims de proyecto).

4. **Rendimiento:** No hay diferencia de rendimiento en la compilación final entre usar nim.cfg o config.nims.

5. **Seguridad:** config.nims puede ejecutar código arbitrario, así que solo usa archivos de fuentes confiables.
