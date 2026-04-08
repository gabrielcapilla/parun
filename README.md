# Parun

A powerful terminal-based package manager for Pacman, AUR, and Nimble

![preview](preview.webp)

## Features

- Unified management: Pacman, AUR, and Nimble packages
- Multi-selection and batch operations
- Real-time search with package details

## Install

<!--```bash
nimble install parun
```-->

From source:

```bash
git clone https://github.com/gabrielcapilla/parun.git
cd parun
nimble build -d:release
cp $(pwd)/parun $HOME/.local/bin/
```

## Usage

```bash
parun
parun --help
parun --aur
parun --nimble
parun --noinfo
parun --aur --pacman --nimble
```

Default mode is local (`pacman`).

If any of `--pacman`, `--aur`, or `--nimble` is passed, those flags define the active source set.

## Search Prefixes

- `aur/` (alias `a/`)
- `nim/` (aliases `n/`, `nimble/`)
- `installed/` (alias `i/`)

## Keys

- `Esc`: quit
- `F1`: toggle info panel
- `Tab`: select/deselect package
- `Enter`: install focused package or selected set
- `Ctrl+R`: remove selected
- `Ctrl+S`: show only selected

## Nimble Tasks

```bash
nimble release          # deterministic release build
nimble releaseNative    # local host-optimized build
```

---

#### Repository & Support

- [GitHub](https://github.com/gabrielcapilla/parun)
