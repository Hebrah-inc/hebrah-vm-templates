# hebrah-vm-templates

Golden NixOS microVM templates for the hebrah platform.

| Template | Purpose |
|----------|---------|
| `sidecar-base` | Connection sidecar (health, HL7, writeback, WireGuard) |
| `py-base` | Customer Python workloads |
| `node-base` | Customer Node workloads |
| `static-base` | nginx static sandbox |

## Build (macOS)

Requires Lima Linux builder — see [documentation/local-microvm-development.md](../documentation/local-microvm-development.md).

```bash
bash scripts/setup-nix-linux-builder.sh
nix build .#packages.aarch64-darwin.sidecar-base
```

## Promote to local golden registry

```bash
bash scripts/hebrah-golden-promote.sh sidecar-base@1.0.0
```

Installs to `~/.hebrah/golden/<hash>/` with `launch.sh`, `manifest.json`, and `smoke.ok`.

## Orchestrator

Set `HYPERVISOR=golden-qemu` and `GOLDEN_TEMPLATE=sidecar-base` after promoting.
