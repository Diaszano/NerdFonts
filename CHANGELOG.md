# 1.0.0 (2025-12-14)


### Features

* add an interactive installation script for Nerd Fonts using Homebrew and fzf ([48da246](https://github.com/Diaszano/NerdFonts/commit/48da246fec3270606515271b7ffc184064c1a464))

## Unreleased

- Prefer direct user installation on Linux and Homebrew with direct fallback on macOS.
- Preserve exact Homebrew/Pacman package names; cache catalogs and resolve known aliases.
- Install direct font families in isolated folders with validated ownership manifests.
- Remove only tracked font files; preserve unmanaged and legacy installations.
- Validate CLI/backend/jobs, retry transient downloads and clean up interrupted jobs.
- Propagate development bootstrap errors and add offline tests, lint and Linux/macOS CI.
