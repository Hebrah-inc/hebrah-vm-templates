# Contributing to hebrah-vm-templates

Thanks for your interest in the hebrah microVM platform.

## Repo scope

This repo contains the **golden NixOS microVM templates** that the hebrah
orchestrator launches for customer sandboxes:

| Path | Purpose |
|------|---------|
| `flake.nix` | Flake outputs — `packages.<host>.sidecar-base` / `py-base` / `node-base` / `static-base`, dev shells, and `nixosConfigurations` for local smoke tests. |
| `templates/` | NixOS module fragments (`sidecar-module.nix`, `py-base-module.nix`, `node-base-module.nix`, `static-base-module.nix`) composed into each template. |
| `packages/` | Python services that ship inside the sidecar guest: health, HL7, writeback, synthetic EHR. |
| `scripts/` | Firecracker launch + snapshot helpers used by the orchestrator's `golden-qemu` and `firecracker` backends. |

It is **not** the control plane (see [`hebrah-api`](https://github.com/Hebrah-inc/hebrah-api))
and it is **not** the orchestrator (the `golden_qemu` / `firecracker` backends
in `hebrah-api/orchestrator/`).

## Development setup

You need Nix with flakes enabled:

```bash
# macOS — recommended: Determinate Nix or the official installer
# Linux — the official installer works directly
nix --extra-experimental-features 'nix-command flakes' build .#packages.x86_64-linux.sidecar-base
```

If you're on macOS you'll want a Linux builder for the `*linux` outputs:

```bash
# See https://github.com/nix-darwin/nix-darwin or Lima + nix-docker
# The hebrah monorepo ships a helper:
#   bash scripts/setup-nix-linux-builder.sh   (umbrella repo only)
```

For local smoke testing of an orchestrator that uses these templates, you'll
also want:

```bash
# In the hebrah umbrella repo:
#   bash scripts/hebrah-golden-promote.sh sidecar-base@1.0.0
# See documentation/vm-platform-architecture.md for the full dev loop.
```

External contributors who don't have the umbrella repo can still:

1. `nix flake show` to see all outputs.
2. `nix build .#packages.x86_64-linux.sidecar-base` to build a template.
3. `nix develop` for an interactive shell with `nix`, `nixfmt-classic`, `jq`,
   `curl` on `$PATH`.

## Code style

- **Nix**: `nixfmt` (the formatter is in the dev shell). CI rejects unformatted
  changes.
- **Python**: PEP 8 + `pathlib` + `argparse`. The guest services use
  `BaseHTTPHandler` deliberately to keep the rootfs small; please don't
  introduce `flask`/`fastapi` dependencies without discussion.
- **Shell**: `set -euo pipefail` at the top of every script. No `bash` features
  beyond 5.x.

## Adding a new template

1. Drop a `templates/<name>-module.nix` next to the existing ones.
2. Reference its packages from `templates/<name>/<name>-module.nix`.
3. Add an entry to `templateSpecs` in `flake.nix` (name, hostname, host module).
4. Run `nix flake check` and `nix build .#packages.<host>.<name>`.
5. Update the README table.

## Adding a new guest service

1. Add `packages/<name>.py` and `packages/<name>.nix` (the `.nix` just
   `readFile`s the `.py` so the rootfs is reproducible from a single source).
2. Mount it from the relevant template (`templates/sidecar/sidecar-module.nix`
   shows the pattern).
3. If it exposes admin endpoints, **always** gate them on
   `X-Hebrah-Internal-Secret` matching the env-loaded secret. See
   `hebrah-synthetic-ehr.py` for the pattern.

## Pull requests

1. Fork the repo and create a branch.
2. Run `nix flake check` before pushing.
3. Keep PRs scoped — one template / one service / one launch script change
   per PR is easier to review.
4. Reference any related issue or design doc.

## Security disclosures

See [SECURITY.md](./SECURITY.md). **Please don't** file public issues for
security bugs — email security@hebrah.com instead.