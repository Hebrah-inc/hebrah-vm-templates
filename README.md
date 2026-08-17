# hebrah-vm-templates

Golden NixOS microVM templates for the [Hebrah](https://github.com/Hebrah-inc)
sandbox platform — sidecar, Python, Node, and static workloads.

| Template | Purpose |
|----------|---------|
| `sidecar-base` | Connection sidecar (health, HL7 v2, FHIR R4, writeback) |
| `py-base` | Customer Python workloads |
| `node-base` | Customer Node workloads |
| `static-base` | nginx static sandbox |

This repo ships **only the templates**. The orchestrator that launches them
lives in [`hebrah-api`](https://github.com/Hebrah-inc/hebrah-api). The MCP
server that exposes them to agents lives in
[`hebrah-mcp-host`](https://github.com/Hebrah-inc/hebrah-mcp-host).

## Quick start

You need Nix with flakes enabled.

```bash
# Build a template for your host
nix --extra-experimental-features 'nix-command flakes' build .#packages.x86_64-linux.sidecar-base

# See all outputs
nix --extra-experimental-features 'nix-command flakes' flake show

# Interactive dev shell (nix, nixfmt-classic, jq, curl)
nix --extra-experimental-features 'nix-command flakes' develop
```

For the full local-dev loop (Lima Linux builder, `setup-nix-linux-builder.sh`,
golden-image promotion with `hebrah-golden-promote.sh`), see the umbrella repo
docs:

- [vm-platform-architecture.md](https://github.com/Hebrah-inc/hebrah/blob/main/documentation/vm-platform-architecture.md)
- [local-microvm-development.md](https://github.com/Hebrah-inc/hebrah/blob/main/documentation/local-microvm-development.md)
- [firecracker-ubuntu-hybrid-dev.md](https://github.com/Hebrah-inc/hebrah/blob/main/documentation/firecracker-ubuntu-hybrid-dev.md)

## Layout

```text
.
├── flake.nix                # Outputs: packages.<host>.{sidecar,py,node,static}-base
├── flake.lock
├── LICENSE
├── README.md
├── SECURITY.md
├── CONTRIBUTING.md
├── .gitignore
├── ARTIFACT_VERSION          # Bumped by the hebrah release process
├── packages/                # Python services that ship inside the guest
│   ├── clinic-fhir-server.py
│   ├── clinic-hl7-server.py
│   ├── hebrah-sidecar-health.{py,nix}
│   ├── hebrah-sidecar-hl7.{py,nix}
│   ├── hebrah-sidecar-writeback.{py,nix}
│   └── hebrah-synthetic-ehr.{py,nix}
├── scripts/                 # Firecracker launch + snapshot helpers
│   ├── launch-firecracker.sh
│   ├── fc-snapshot-create.sh
│   ├── fc-snapshot-resume.sh
│   ├── fc-snapshot-lib.sh
│   └── fc-hot-claim.sh
└── templates/               # NixOS module fragments
    ├── sidecar/sidecar-module.nix
    ├── py-base/py-base-module.nix
    ├── node-base/node-base-module.nix
    └── static-base/static-base-module.nix
```

## How the templates are used

The hebrah-api orchestrator's `golden-qemu` and `firecracker` backends:

1. Promote a template to the **local golden registry**
   (`~/.hebrah/golden/<sha256>/launch.sh`) — this is done by the umbrella
   `scripts/hebrah-golden-promote.sh` helper.
2. On each customer claim, run `launch-firecracker.sh` to start a Firecracker
   microVM with the per-tenant `hebrah-config` directory mounted over 9p.
3. Poll `/health.json` over the host→guest tap until ready, then DNAT-forward
   the customer's ports to localhost.

See [vm-platform-architecture.md](https://github.com/Hebrah-inc/hebrah/blob/main/documentation/vm-platform-architecture.md)
for the full design.

## Adding a template or guest service

See [CONTRIBUTING.md](./CONTRIBUTING.md). Quick rules:

- New template → drop a `templates/<name>-module.nix`, add a `templateSpecs`
  entry in `flake.nix`, update the table above.
- New guest service → `packages/<name>.{py,nix}` and reference it from the
  relevant template. If it exposes admin endpoints, **always** gate them on
  `X-Hebrah-Internal-Secret`.

## Security

See [SECURITY.md](./SECURITY.md). Please report vulnerabilities privately to
security@hebrah.com.

## License

MIT — see [LICENSE](./LICENSE).