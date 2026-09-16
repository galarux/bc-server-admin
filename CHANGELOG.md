# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-09-16

### Added

- Galarux branding: logo in the top bar and sidebar, corporate colours in both themes, and an **About** dialog with website, contact and products.
- The HTML export report carries the Galarux logo (embedded, so the file stays standalone) and links.
- README banners and a social preview image (`docs/images/social-preview.png`).

## [1.0.0] - 2026-09-16

### Added

- Local web UI (English / Spanish, light / dark) served by a dependency-free PowerShell script.
- Automatic discovery of every `MicrosoftDynamicsNavServer$*` service, its version, Service folder and `CustomSettings.config`.
- Start, stop and restart instances without blocking the UI.
- Configuration editor grouped like the old MMC tabs, with search, descriptions taken from the config file, value hints, masked secrets and optional live apply (`-ApplyTo Memory`).
- SQL credentials dialog (`Set-NAVServerConfiguration -DatabaseCredentials`).
- Automatic `CustomSettings.config` backup before every change, with a list and restore.
- Sessions (list and end), tenants, and the instance event log (BC Admin log and Windows Application log).
- Side-by-side configuration comparison of two instances.
- HTML / CSV / JSON export, from the UI or from the command line (`-ExportPath`).
- One PowerShell worker process per BC version so side-by-side installations work; PowerShell 7 is used for BC 24-28 when available.
- `-Demo` mode with fictitious instances, used by the tests and the screenshots.

[1.1.0]: https://github.com/galarux/bc-server-admin/releases/tag/v1.1.0
[1.0.0]: https://github.com/galarux/bc-server-admin/releases/tag/v1.0.0
