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
parun --no-animation
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
- `Up` / `Ctrl+K`: move selection up
- `Down` / `Ctrl+J`: move selection down
- `Tab`: select/deselect package
- `Enter`: install focused package or selected set
- `Ctrl+R`: remove selected
- `Ctrl+S`: show only selected

## Nimble Tasks

```bash
nimble baseline_x86_64     # portable GitHub Release binary
nimble baseline_x86_64_v3  # optimized x86-64-v3 GitHub Release binary
nimble native              # local host-optimized build
```

---

#### Repository & Support

- [GitHub](https://github.com/gabrielcapilla/parun)
