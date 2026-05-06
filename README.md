# parun

Terminal UI for Arch Linux package management.

Parun brings Pacman, AUR, and Nimble packages into one fast interface with
real-time search, package details, multi-selection, and batch operations.

![preview](preview.webp)

## Install

```bash
curl -sL gabrielcapilla.github.io/install | bash -s parun
```

The installer downloads the latest GitHub release and selects the portable
`x86_64` binary or the optimized `x86_64-v3` binary for the current CPU.

## Usage

```bash
parun
```

Useful prefixes:

- `aur/` or `a/`
- `nim/`, `n/`, or `nimble/`
- `installed/` or `i/`

Useful keys:

- `F1`: toggle details
- `Up` / `Ctrl+K`: move up
- `Down` / `Ctrl+J`: move down
- `Tab`: select package
- `Enter`: install focused or selected packages
- `Ctrl+R`: remove selected packages
- `Ctrl+S`: review selected packages

## Build

```bash
nimble build -d:release
nimble baseline_x86_64
nimble baseline_x86_64_v3
nimble native
```

Documentation: https://gabrielcapilla.github.io/projects/parun/docs/
