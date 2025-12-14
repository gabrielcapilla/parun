**Parun** is an elegant and efficient Terminal UI (TUI) for managing packages on Arch-based Linux systems, like CachyOS, Manjaro or Arch Linux. Written in [Nim](https://nim-lang.org/), it acts as a visual interface for `pacman`, `paru`, or `yay`, simplifying the process of searching, installing, and uninstalling packages from official repositories, the AUR (Arch User Repository), and Nimble (the Nim package manager).

---

## Features

- **Intuitive TUI Interface:** Visual interaction directly within the terminal.
- **Multi-Manager Compatibility:**
  - Supports `paru`, `yay`, and `pacman` as backends.
- **AUR Support:** Switch between Local (official repos only) and Local+AUR mode.
- **Detailed View:** Inspect detailed information about selected packages.
- **Bulk Selection:** Mark multiple packages for concurrent installation or removal.
- **Live Search:** Filter packages in real-time as you type in the search field.
- **Optional Vim Mode:** Vim-style keyboard shortcuts for navigation and editing.
- **Nimble Support:** Browse and install Nim packages directly from the TUI.

---

## Installation

### Prerequisites

- An Arch-based Linux distribution (the `pacman` package manager must be available).
- `nim >= 2.2.6`
- `nimsimd >= 1.3.2`

### Steps

1. Clone this repository:

   ```bash
   git clone https://github.com/gabrielcapilla/parun.git
   cd parun
   ```

2. Install:

   ```bash
   nimble install
   ```

3. Optionally, you can build in "release" mode for better performance. This builds in release mode as defined in the .nimble file and installs the binary in `$HOME/.local/bin`

   ```bash
   nimble release
   ```

4. To run it directly from the terminal:
   ```bash
   parun
   ```

---

## Usage

```bash
parun [options]
```

### Options

- `--aur`: Start in _Local+AUR_ mode.
- `--noinfo`: Do not show the detailed package information panel.
- `--vim`: Enable Vim-style mode.
- `--nimble`: Start displaying Nimble packages instead of system packages.

### Keyboard Shortcuts

#### Standard Mode

| Action                        | Key(s)                   |
| ----------------------------- | ------------------------ |
| Move cursor up                | `↑`                      |
| Move cursor down              | `↓`                      |
| Next page                     | `PgDown`                 |
| Previous page                 | `PgUp`                   |
| Toggle details panel          | `F1`                     |
| Type to search packages       | Type in the `>` prompt   |
| Insert/Delete character       | Normal keys              |
| Backspace                     | `Backspace` or `Del`     |
| Select packages               | `Tab`                    |
| Install selected package(s)   | `Enter`                  |
| Uninstall selected package(s) | `Ctrl+R`                 |
| Toggle between Local/AUR      | `Ctrl+A`                 |
| Toggle Selection/Normal view  | `Ctrl+S`                 |
| Quit                          | `Esc` or `Alt+Backspace` |

#### Vim Mode (`--vim`)

| Action                         | Mode              | Command              |
| ------------------------------ | ----------------- | -------------------- |
| Move cursor up                 | Normal            | `k` or `↑`           |
| Move cursor down               | Normal            | `j` or `↓`           |
| Next page                      | Normal            | `Ctrl+D` or `PgDown` |
| Previous page                  | Normal            | `Ctrl+U` or `PgUp`   |
| Go to top                      | Normal            | `g` or `Home`        |
| Go to bottom                   | Normal            | `G` or `End`         |
| Scroll details up              | Normal            | `Ctrl+Y`             |
| Scroll details down            | Normal            | `Ctrl+E`             |
| Toggle details panel           | Normal            | `F1`                 |
| Enter insert mode (search)     | Normal            | `i` or `/`           |
| Enter command mode (e.g. `:q`) | Normal            | `:`                  |
| Select package                 | Normal            | `<Space>`            |
| Install package                | Normal            | `Enter`              |
| Uninstall package              | Normal            | `x`                  |
| Toggle between Local/AUR       | Normal            | `Ctrl+A`             |
| Toggle Selection/Normal view   | Normal            | `Ctrl+S`             |
| Quit                           | Normal or Command | `:q` or `:q!`        |

---

## Configuration

Parun does not require an external configuration file. However, it internally interacts with `pacman`, `paru`, `yay`, and `nimble` commands. Ensure these are installed.

### Relevant Environment Variables

- `$PACMAN`: The primary package manager (usually `pacman`, `paru`, or `yay`). Parun detects it automatically.
- `$HOME/.nimble/packages_official.json`: Required by `--nimble` mode. Can be created with `nimble refresh`.

## Repository & Support

- **GitHub:** [gabrielcapilla/parun](https://github.com/gabrielcapilla/parun)
- **Nostr:** [@gabrielcapilla](https://nostree.me/npub1uf2dtc8wfpd7g4papst44uy0yzlnud54tzglhffrr3yvh6hnjefq4uy52e)
