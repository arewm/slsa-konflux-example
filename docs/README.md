# Documentation

This directory contains tutorials, architectural references, and implementation guides for end-to-end SLSA compliance and task-scoped workload identity in Konflux.

---

## Tutorials (Hands-On Learning)

Step-by-step walkthroughs to onboard components, build containers, and enforce policy:

- **[Part 1: Build and Release](tutorials/part1-build-and-release.md)**  
  Onboard an example component (Festoji), understand SLSA Build Level 3 controls, inspect OCI 1.1 referrers (SBOM, provenance, signatures), and verify releases as an external consumer.

- **[Part 2: Source Track, Vulnerability Management, and Hermetic Builds](tutorials/part2-source-and-vulnerabilities.md)**  
  Advanced controls using `source-test-repo`: SLSA Source Level 3 via `source-tool`, per-application Conforma policies, CVE leeway and volatile exceptions, and hermetic build isolation.

---

## Reference (Architecture & Threat Models)

Technical references and operator specifications to consult as needed:

- **[Trusting Artifacts: Architecture and Threat Model](reference/trusting-artifacts.md)**  
  The core supply chain threat model: why Tekton Chains signs unverified outputs, why PersistentVolumeClaims undermine task trust, how OCI Trusted Artifacts enforce immutability, and how Verification Summary Attestations (VSAs) delegate consumer trust.

- **[CI Workload Identity Patterns](reference/workload-identity-patterns.md)**  
  A taxonomy of five production patterns using Kyverno and SPIFFE/SPIRE: separation of duties in attestation signing, federated OCI push gating, secretless internal APIs, cloud IAM federation, and release boundary gating.

- **[Dual-Gated Release Authority Guide](reference/dual-gated-release.md)**  
  Implementation runbook for Model 2 release gating in `managed-tenant`, including Kyverno and SPIRE conjunction rules, dual-mode keyless signing, and Rekor verification commands.

---

## Live Demonstration

- **[KubeCon NA 2026 Live Demo Guide](../demo/README.md)**  
  Interactive 4-act terminal presentation script (`demo/run-demo.sh`), multi-port `ttyd` slide server, and setup automation.
