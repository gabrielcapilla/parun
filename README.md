# parun

Terminal UI for paru or pacman - A fast, interactive package manager interface for Arch Linux systems.

## Features

- **Interactive TUI**: Clean, keyboard-driven interface for browsing packages
- **Fast Search**: Real-time fuzzy search through package repositories
- **Dual Package Manager Support**: Works with both `paru` and `pacman`
- **Package Management**: Install and uninstall packages directly from the interface
- **Detailed View**: Optional package details panel for more information
- **Visual Feedback**: Color-coded interface showing installed packages and selection status

## Installation

### Prerequisites

- Nim 2.2.6 or higher
- For building: nimble package manager
- System package managers: `pacman` (required), `paru` or `yay` (optional, for AUR support)

### Building from Source

1. **Clone the repository:**
   ```bash
   git clone https://github.com/yourusername/parun.git
   cd parun
   ```

2. **Build the project:**
   ```bash
   nimble build
   ```

3. **Alternatively, build in release mode:**
   ```bash
   nimble r  # This builds and runs in release mode
   nimble b  # This just builds in release mode
   ```

## Usage

### Running the Application

```bash
./parun
```

Or if installed system-wide:
```bash
parun
```

### Controls

- **Navigation**:
  - `↑` / `↓`: Move cursor up/down in the package list
  - `Tab`: Select/deselect the current package
  - `Ctrl+R`: Mark selected package(s) for removal
  - `Enter`: Install selected package(s) or the currently highlighted package

- **Search**:
  - Type to search packages in real-time
  - `Backspace` / `Delete`: Remove characters from search query
  - `Esc`: Clear search query or quit if search is empty

- **View**:
  - `F1`: Toggle details panel on/off
  - `Tab`: Toggle package selection

### Functionality

When launched, `parun` loads all available packages from the system's package repositories using `pacman -Sl`. It displays them in an interactive terminal interface where you can:

1. Search packages using fuzzy matching
2. Select one or multiple packages
3. View package details in the side panel
4. Install or remove packages with keyboard shortcuts

The application automatically detects and uses `paru` if available for AUR support, falling back to `pacman` otherwise.

## Configuration

`parun` uses the system's existing package manager configuration files (`/etc/pacman.conf`, etc.) and does not require additional configuration.

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Commit your changes (`git commit -m 'Add some amazing feature'`)
5. Push to the branch (`git push origin feature/amazing-feature`)
6. Open a pull request

## License

MIT License - see the [LICENSE](LICENSE) file for details.

---

*Note: This project interfaces with Arch Linux's package management system and requires appropriate permissions for installation/removal of packages.*