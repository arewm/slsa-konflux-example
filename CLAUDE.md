# CLAUDE.md

End-to-end SLSA compliance using Konflux. Working implementation with strict trust boundary separation between tenant (builds) and managed (releases, signing) namespaces.

## Repository Structure

```
charts/platform-config/      — One-time cluster setup: signing keys, RBAC, policies
charts/component-onboarding/  — Per-component: app, integration tests, release plan
managed-context/              — Platform-controlled: release tasks, pipelines, policies (see AGENTS.md)
hack/                         — Build/push scripts for pipeline and task bundles
scripts/                      — Cluster setup automation
docs/                         — Walkthroughs: part1 (build+release), part2 (source+CVEs+hermetic)
```

## Invariants

- **Trust boundary**: tenant and managed contexts must remain isolated. Signing keys exist only in the managed namespace.
- **Policy evaluation**: must occur in managed context only, via `verify-conforma` before any image push.
- **Artifact immutability**: all bundle references pinned by digest. `managed-context/slsa-e2e-pipeline/bundle-ref` is the source of truth for the build pipeline bundle.

Setup commands and architecture details are in `README.md` and `docs/`.
