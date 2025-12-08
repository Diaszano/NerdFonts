# Nerd Fonts Installer

Command-line utility to streamline installing Nerd Fonts on macOS and Linux using Homebrew.
It provides an interactive `fzf`-based picker to quickly provision and maintain a consistent developer font setup across environments.

---

## Table of Contents

- [Nerd Fonts Installer](#nerd-fonts-installer)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Quick Start (Copy \& Paste)](#quick-start-copy--paste)
    - [1. Run directly with `curl` (no clone required)](#1-run-directly-with-curl-no-clone-required)
    - [2. If you prefer to clone the repository](#2-if-you-prefer-to-clone-the-repository)
      - [2.1 Install Homebrew (if you do not have it)](#21-install-homebrew-if-you-do-not-have-it)
      - [2.2 Install `fzf` via Homebrew](#22-install-fzf-via-homebrew)
      - [2.3 Clone this repository and run the installer](#23-clone-this-repository-and-run-the-installer)
      - [2.4 One-liner (clone + run interactive installer)](#24-one-liner-clone--run-interactive-installer)
  - [Features](#features)
  - [Requirements](#requirements)
  - [Installation](#installation)
    - [Option 1 – Use `make` (recommended for contributors)](#option-1--use-make-recommended-for-contributors)
    - [Option 2 – Run the script directly](#option-2--run-the-script-directly)
  - [Usage](#usage)
    - [Interactive mode](#interactive-mode)
    - [Install all fonts](#install-all-fonts)
  - [Makefile targets](#makefile-targets)
    - [`dev-install`](#dev-install)
    - [`brew-install`](#brew-install)
    - [`pre-commit-install`](#pre-commit-install)
    - [`pre-commit`](#pre-commit)
    - [`run`](#run)
  - [Project structure](#project-structure)
  - [Development workflow](#development-workflow)
  - [Troubleshooting](#troubleshooting)
  - [Contributing](#contributing)
  - [License](#license)

---

## Overview

This project provides a simple and opinionated way to install Nerd Fonts via Homebrew.
Instead of manually searching and installing font casks, you can run a single script, select the fonts you want in an interactive UI and let the tool handle the rest.

The primary entry point is:

- `scripts/install.sh` – interactive installer script using `bash` + `fzf` + Homebrew.

---

## Quick Start (Copy & Paste)

### 1. Run directly with `curl` (no clone required)

Using **process substitution** (works in `bash` and `zsh`):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Diaszano/NerdFonts/main/scripts/install.sh)
````

Or, using a classic pipe:

```bash
curl -fsSL https://raw.githubusercontent.com/Diaszano/NerdFonts/main/scripts/install.sh | bash
```

> ⚠️ This will always run the latest version of the installer from the `main` branch.

### 2. If you prefer to clone the repository

#### 2.1 Install Homebrew (if you do not have it)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

#### 2.2 Install `fzf` via Homebrew

```bash
brew install fzf
```

#### 2.3 Clone this repository and run the installer

```bash
git clone https://github.com/Diaszano/NerdFonts.git
cd NerdFonts
chmod +x scripts/install.sh
./scripts/install.sh
```

#### 2.4 One-liner (clone + run interactive installer)

```bash
git clone https://github.com/Diaszano/NerdFonts.git \
  && cd NerdFonts \
  && chmod +x scripts/install.sh \
  && ./scripts/install.sh
```

---

## Features

* ✅ Cross-platform: supports macOS and Linux where Homebrew is available
* ✅ Interactive font selection with `fzf` (multi-select)
* ✅ Optional “install all fonts” mode
* ✅ Safe execution with strict `bash` options (`set -euo pipefail`)
* ✅ Colorized and structured terminal output for better UX
* ✅ Makefile targets to bootstrap development environment

---

## Requirements

* **Operating system**

  * macOS
  * Linux

* **Runtime**

  * `bash`

* **Tooling**

  * [Homebrew](https://brew.sh)
  * [`fzf`](https://github.com/junegunn/fzf)

    > If `fzf` is not installed, the script can install it via Homebrew (assuming `brew` is available).

---

## Installation

Clone the repository:

```bash
git clone https://github.com/Diaszano/NerdFonts.git
cd NerdFonts
```

You can either:

### Option 1 – Use `make` (recommended for contributors)

```bash
make dev-install
```

This will typically:

1. Ensure Homebrew is installed (if your Makefile is configured for that).
2. Install and configure `pre-commit` hooks (if present in the project).

### Option 2 – Run the script directly

Make the script executable (if needed):

```bash
chmod +x scripts/install.sh
```

Then run:

```bash
./scripts/install.sh
```

---

## Usage

All commands below assume you are in the project root.

### Interactive mode

Run the installer in interactive mode (default):

```bash
./scripts/install.sh
```

Behavior:

* Validates basic requirements (Homebrew, etc.).
* Discovers available Nerd Font casks from Homebrew.
* Opens an `fzf` window where you can **multi-select** fonts.
* For each selected font, asks for confirmation before installing (per-font confirmation).

### Install all fonts

To install **all available Nerd Fonts** without per-font confirmation:

```bash
./scripts/install.sh --all
```

Behavior:

* Skips the interactive per-font confirmation step.
* Iterates all discovered Nerd Font casks and installs them via Homebrew.

> ⚠️ **Note:** This may install a large number of fonts and consume time and disk space.

---

## Makefile targets

If you are using `make`, the project exposes some convenience targets.

### `dev-install`

```bash
make dev-install
```

* Orchestrates the initial development setup.
* Usually runs:

  * `brew-install`
  * `pre-commit-install`

### `brew-install`

```bash
make brew-install
```

* Ensures Homebrew is installed on the system.
* On macOS/Linux, it uses the official Homebrew installation script if `brew` is not found in `PATH`.

Example snippet (for reference):

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### `pre-commit-install`

```bash
make pre-commit-install
```

* Installs `pre-commit` via Homebrew.
* Installs the project’s `pre-commit` hooks, including `commit-msg` hooks if configured.

### `pre-commit`

```bash
make pre-commit
```

* Runs all configured pre-commit hooks against the entire codebase.

### `run`

```bash
make run
```

* Convenience target to run the main script. Typical mapping:

```make
run:
	./scripts/install.sh
```

---

## Project structure

A typical layout might look like this:

```text
.
├── scripts
│   └── install.sh              # Main Nerd Fonts installer script
├── .editorconfig               # Editor configuration (if present)
├── .gitignore                  # Git ignore rules
├── Makefile                    # Dev and run targets
├── .pre-commit-config.yaml     # Pre-commit configuration (if present)
└── README.md                   # Project documentation
```

---

## Development workflow

1. **Bootstrap tooling**

   ```bash
   make dev-install
   ```

2. **Run pre-commit locally**

   ```bash
   make pre-commit
   ```

3. **Modify scripts**

   * Update `scripts/install.sh` to refine:

     * Font discovery logic
     * `fzf` options (prompt, layout, height, multi-select, etc.)
     * Logging and colorized output

4. **Test changes**

   ```bash
   ./scripts/install.sh
   # or
   make run
   ```

---

## Troubleshooting

* **Homebrew not found**

  * Ensure `brew` is in your `PATH`.
  * On macOS and Linux (Homebrew), this usually means adding something like:

    ```bash
    eval "$(/opt/homebrew/bin/brew shellenv)"   # Apple Silicon
    # or
    eval "$(/usr/local/bin/brew shellenv)"      # Intel / common Linux
    ```

* **fzf not installed**

  * Install it via Homebrew:

    ```bash
    brew install fzf
    ```

* **Fonts not showing up in terminal**

  * After installing fonts, make sure to:

    * Open your terminal emulator preferences.
    * Select the installed Nerd Font as the active font.
    * Restart the terminal if necessary.

---

## Contributing

Contributions are welcome.

* Fork the repository.
* Create a feature branch.
* Commit changes with clear messages.
* Open a pull request describing:

  * What was changed.
  * Why it is valuable.
  * Any additional steps or breaking changes.

---

## License

This project is licensed under the terms specified in the [`LICENSE`](./LICENSE) file.
Review that file for details before using or distributing this code.
