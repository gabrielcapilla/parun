# parun

A powerful terminal-based package manager for Pacman, AUR, and Nimble. Parun brings Pacman, AUR, and Nimble packages into one fast interface with
real-time search, package details, multi-selection, and batch operations.

![preview](preview.webp)

## Full documentation

https://gabrielcapilla.github.io/projects/parun/docs/

## Install

```bash
curl -sL gabrielcapilla.github.io/install | bash -s parun
```

The installer downloads the latest GitHub release and selects the portable
`x86_64` binary or the optimized `x86_64-v3` binary for the current CPU.

### Build From source:

```bash
git clone https://github.com/gabrielcapilla/parun.git &&
cd parun &&
nimble tasks &&
nimble native &&
cp $(pwd)/parun $HOME/.local/bin/ &&
echo "Installed $HOME/.local/bin/parun"
```

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

## Nimble Tasks

```bash
nimble native
nimble baseline_x86_64
nimble baseline_x86_64_v3
```

---

#### Repository & Support

- [GitHub](https://github.com/gabrielcapilla/parun)
