# Parun

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
- `nimsimd >= 1.2.0`

### Steps

1. Clone this repository:

   ```bash
   git clone https://github.com/gcapilla/parun.git
   cd parun
   ```

2. Build the project:

   ```bash
   nimble build
   ```

   This will generate the `parun` executable inside the `src` folder.

3. Optionally, you can build in "release" mode for better performance:

   ```bash
   nimble r  # This also builds in release mode as defined in the .nimble file
   ```

4. To run it directly from the project directory:
   ```bash
   ./src/parun
   ```

---

## 💡 Usage

```bash
parun [options]
```

### Options

- `-a`, `--aur`: Start in _Local+AUR_ mode.
- `-n`, `--noinfo`: Do not show the detailed package information panel.
- `--vim`: Enable Vim-style editing mode.
- `--nimble`: Start displaying Nimble packages instead of system packages.

### Keyboard Shortcuts

#### Standard Mode

| Action                        | Key(s)                 |
| ----------------------------- | ---------------------- |
| Move cursor up                | `↑`                    |
| Move cursor down              | `↓`                    |
| Next page                     | `PgDown`               |
| Previous page                 | `PgUp`                 |
| Go to top                     | `Home`                 |
| Go to bottom                  | `End`                  |
| Scroll details up             | `Ctrl+Y`               |
| Scroll details down           | `Ctrl+E`               |
| Toggle details panel          | `F1`                   |
| Type to search packages       | Type in the `>` prompt |
| Insert/Delete character       | Normal keys            |
| Backspace                     | `Backspace` or `Del`   |
| Select packages               | `Tab`                  |
| Install selected package(s)   | `Enter`                |
| Uninstall selected package(s) | `Ctrl+R`               |
| Toggle between Local/AUR      | `Ctrl+A`               |
| Toggle Selection/Normal view  | `Ctrl+S`               |
| Quit                          | `Esc` or `Ctrl+C`      |

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

## ⚙️ Configuration

Parun does not require an external configuration file. However, it internally interacts with `pacman`, `paru`, `yay`, and `nimble` commands. Ensure these are installed.

### Relevant Environment Variables

- `$PACMAN`: The primary package manager (usually `pacman`, `paru`, or `yay`). Parun detects it automatically.
- `$HOME/.nimble/packages_official.json`: Required by `--nimble` mode. Can be created with `nimble refresh`.

---

## 🤝 Contributing

Contributions are welcome. If you wish to collaborate:

1. Fork the repository.
2. Create a branch (`git checkout -b feature/NewFeature`).
3. Make your changes and commit them (`git commit -m 'Add new feature'`).
4. Push to the branch (`git push origin feature/NewFeature`).
5. Open a Pull Request.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for more details.
