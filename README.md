# Parun

A powerful terminal-based package manager for Pacman, AUR, and Nimble

![preview](preview.webp)

## Features

- Unified management: Pacman, AUR, and Nimble packages
- Multi-selection and batch operations
- Real-time search with package details

## Install

**Quick install (binary):**

```bash
curl -fsSL gabrielcapilla.github.io/install | bash -s parun
```

**Or install with Nimble (requires Nim):**

```bash
nimble install https://github.com/gabrielcapilla/parun.git@#head
```

## Usage

```bash
parun              # Start in default mode
parun --nimble     # Start in Nimble mode
parun --noinfo     # Hide details panel
```

### Navigation

- **Arrow keys** · Move through packages
- **PgUp / PgDn** · Scroll by pages
- **F1** · Toggle details panel
- **Esc** · Quit

### Package Management

- **Tab** · Select/deselect package for batch operations
- **Enter** · Install highlighted package, or all selected packages
- **Ctrl+R** · Remove selected packages
- **Ctrl+S** · Show only selected

### Quick Search

Type prefixes to switch between package sources:

- **aur/** · Search AUR packages
- **nim/** · Search Nimble packages

---

Parun internally uses `pacman`, `paru`/`yay`, and `nimble` commands.

#### Repository & Support

- [GitHub](https://github.com/gabrielcapilla/parun)
- [Nostr](https://nostree.me/npub1uf2dtc8wfpd7g4papst44uy0yzlnud54tzglhffrr3yvh6hnjefq4uy52e)
