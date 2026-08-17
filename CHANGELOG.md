# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `CODE_OF_CONDUCT.md` (Contributor Covenant v2.1).
- `CHANGELOG.md` (this file).
- Issue templates (bug report, feature request, docs) and PR template under `.github/`.
- GitHub Actions CI: `nix flake check` + `nix build .#packages.x86_64-linux.sidecar-base`.
- OSS discovery badges in README (License, NixOS-unstable, microvm.nix, GitHub stars + issues).

## [2026.07-fc-provision-phase1] — 2026-07-16

### Added

- Open-source release of the golden VM templates — `sidecar-base`, `sidecar-base-fc`, `py-base`, `node-base`, `static-base`.
- Firecracker launch + snapshot helpers under `scripts/` (`launch-firecracker.sh`, `fc-snapshot-{create,resume}.sh`, `fc-snapshot-lib.sh`, `fc-hot-claim.sh`).
- Guest Python services: `hebrah-sidecar-{health,hl7,writeback,synthetic-ehr}.{py,nix}` and clinic FHIR/HL7 servers.
- Tap-bound admin endpoints on `:8091` with `X-Hebrah-Internal-Secret` gating.

> Versioning follows `<year>.<month>-<milestone>` since this repo ships a single rolling release (`main`). No LTS branches are maintained.

[Unreleased]: https://github.com/Hebrah-inc/hebrah-vm-templates/compare/2026.07-fc-provision-phase1...HEAD
[2026.07-fc-provision-phase1]: https://github.com/Hebrah-inc/hebrah-vm-templates/releases/tag/2026.07-fc-provision-phase1