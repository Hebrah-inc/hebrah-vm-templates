# Security policy

## Reporting a vulnerability

If you discover a security vulnerability in `hebrah-vm-templates`, please report
it privately to **security@hebrah.com** (or open a private security advisory
via GitHub: <https://github.com/Hebrah-inc/hebrah-vm-templates/security/advisories/new>).

Please **do not** file a public issue for suspected vulnerabilities.

Include as much of the following as you can:

- A clear description of the issue and its impact (RCE, privilege escalation,
  information disclosure, denial of service, etc.).
- Reproduction steps or a proof-of-concept.
- The affected version (`git rev-parse HEAD` is great).
- Your assessment of exploitability and affected configurations
  (e.g. "only when `HEBRAH_INTERNAL_SECRET` is unset").

We aim to acknowledge reports within **3 business days** and to coordinate
disclosure timelines with reporters.

## What this repo protects against

`hebrah-vm-templates` provides NixOS microVM templates and the Firecracker launch
shells used by the hebrah orchestrator. The threat model for an operator who
runs these templates is roughly:

| Boundary | Mechanism |
|----------|-----------|
| Guest → host via Firecracker admin API | `HEBRAH_INTERNAL_SECRET` (shared secret) on `X-Hebrah-Internal-Secret` header for `/admin/*` endpoints. The guest's `hebrah-sidecar-*` services only accept admin requests when the header matches. |
| Snapshot env injection | `fc-snapshot-create.sh` and `fc-hot-claim.sh` validate the `hebrah.env` content before writing it to the guest's MMDS. Reload-env is gated on the same shared secret. |
| Snapshot file tampering | `fc-snapshot-resume.sh` validates the snapshot file format before `LoadSnapshot`. |
| Guest port exposure | `launch-firecracker.sh` only DNAT-forwards the documented ports (health/writeback/HL7/MLLP/FHIR) to localhost; the Firecracker guest has no public IP. |

## What this repo does NOT protect against

This repo is **not** a security boundary on its own. An operator must also:

- Run the orchestrator with proper isolation (separate `hebrah-config` directory,
  no privileged access from customer workloads).
- Rotate `HEBRAH_INTERNAL_SECRET` between golden images and never bake a
  long-lived secret into the flake. Treat it like a per-environment shared
  secret, not a long-term API key.
- Keep `microvm.nix` and `nixpkgs` up to date — see [CONTRIBUTING.md](./CONTRIBUTING.md).
- Audit guest workloads (`py-base`, `node-base`, `static-base`); these run
  customer code in the guest and inherit the customer's threat model.

For the platform-level threat model (PATs, API keys, webhook signatures,
control-plane posture), see
[`hebrah-mcp-host/SECURITY.md`](https://github.com/Hebrah-inc/hebrah-mcp-host/blob/main/SECURITY.md)
and the hebrah-api docs.

## Supported versions

| Version | Supported |
|---------|-----------|
| `main` branch HEAD | ✅ |
| Anything older | Best effort |

This repo currently ships a single rolling release (`main`). No LTS branches
are maintained.

## Disclosure timeline

We follow a roughly 90-day responsible-disclosure window. We will coordinate
with reporters on a release date and credit them in the commit / advisory.