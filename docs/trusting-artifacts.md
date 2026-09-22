# Trusting Artifacts: Architecture & Threat Model

## The Core Problem: Chains Signs Anything

[Tekton Chains](https://tekton.dev/docs/chains/) observes completed PipelineRuns and TaskRuns, generates SLSA provenance attestations, and signs them. This observer pattern keeps signing keys separate from build execution.

The tradeoff is that Chains signs whatever artifacts tasks claim to produce. It does not verify whether the task is trustworthy, whether the artifact was actually built in this pipeline, or whether a malicious task swapped in a pre-built image.

Consider what happens when a malicious task enters the pipeline. It claims to build a container image from source, but instead pulls a pre-compromised image from an attacker's registry. It uses Tekton [type hinting](https://tekton.dev/docs/chains/slsa-provenance/#type-hinting) to report this as a "built" artifact. Chains sees a completed task, generates signed SLSA provenance, and now you have cryptographically valid provenance for an artifact that was never actually built from the claimed source.

Signing alone does not solve supply chain security. We need to verify what was signed, who signed it, and whether artifacts remained intact throughout execution.

---

## Shift-Left Trust: Moving Beyond Retroactive Evaluation

Traditional pipeline security models evaluate task trust **retroactively**. Conforma or Enterprise Contract inspects the build provenance *after* the pipeline finishes to check if task bundles were digest-pinned and pulled from an approved catalog.

That works for blocking release promotion, but retroactive evaluation leaves two real gaps:
- **Untrusted code still runs**: An unauthorized or malicious task runs inside your cluster with full network and compute access before policy evaluation ever inspects it.
- **Ambient authority is unconstrained**: During execution, the task shares the same ServiceAccount and ambient secrets as legitimate tasks.

### Moving Verification to Admission

To close those gaps, we shift verification left to admission time:

1. **Kyverno Interception**: When a `TaskRun` is submitted, Kyverno admission policies intercept the request.
2. **Bundle Verification**: The policy verifies that the task definition is pinned to an immutable digest (`@sha256:...`), matches an approved catalog repository pattern, and carries a valid Cosign cryptographic signature.
3. **Role Classification**: Tasks that pass verification receive `trusted-task-role: prod`. Inline, unpinned, or unsigned tasks receive `trusted-task-role: dev`.
4. **Workload Identity (SPIRE)**: The verified pod label is evaluated by SPIRE to issue a fine-grained, task-scoped workload identity (`spiffe://konflux-ci.dev/trusted/...` vs. `.../dev/...`).

This guarantees that trust is established *before* the container starts executing. Downstream verifiers and external services can check the workload's cryptographic identity directly rather than re-evaluating build evidence from scratch.

> For a full breakdown of how task-scoped workload identity enables separation of duties, secretless APIs, and push gating, see **[CI Workload Identity Patterns](task-workload-identity-patterns.md)**.

---

## Task Trust: Provenance & Policy Gating

In addition to admission-time classification, Konflux uses [Conforma](https://conforma.dev) to verify that every task in a build came from an approved source before artifacts can be released.

Conforma's [`trusted_tasks`](https://conforma.dev/docs/policy/packages/release_trusted_task.html) package enforces three requirements:
- Tasks must reference digest-pinned bundles, not mutable tags.
- Those bundles must appear in an approved trusted task list.
- Any task that a policy declares as required must itself be trusted.

---

## Artifact Trust: Why PVCs Are Not Enough

Containers in a pipeline are isolated from each other, but shared volumes tell a different story. When tasks pass data through PVCs, any task with access to the volume can read or modify artifacts left by previous tasks. A single malicious task can tamper with everything. This forces an all-or-nothing trust model: either every task in the pipeline is trusted, or none of the output can be trusted.

That model works, but it has a real cost. Centralized pipeline ownership means every change, even adding a linter, must go through a trust review process. This tension between security and developer autonomy is why Konflux uses [Trusted Artifacts](https://konflux-ci.dev/architecture/ADR/0036-trusted-artifacts.html) instead of PVCs.

### Content-Addressable OCI Artifact Passing

Trusted Artifacts store intermediate data as immutable OCI images, addressed by content digest. Rather than writing to a shared filesystem, each task's output becomes the next task's input through explicit parameter chaining:

1. Task A produces an output archive and pushes it to an OCI registry (or local cache) addressed by its cryptographic SHA256 digest.
2. Task B receives the explicit digest as a Tekton parameter and unpacks the archive.
3. Any modification to intermediate files produces a different digest, immediately breaking the pipeline chain.

This scopes trust narrowly. Because there is no shared volume, untrusted tasks cannot inspect or modify artifacts they never receive. Developers can add custom or unprivileged tasks without compromising the integrity of the core build output.

---

## How This Achieves SLSA Build Level 3

The properties above — task trust verification, artifact immutability, admission-time workload identity, and signing key isolation — form the building blocks of [SLSA Build Level 3](https://slsa.dev/spec/v1.1/requirements):

- **Hardened Ephemeral Builds**: Each build runs in an isolated, ephemeral Kubernetes pod that does not share state or filesystems with other builds.
- **Isolated Signing (Build vs. Release Boundary)**: Build execution runs in an unprivileged tenant namespace (`default-tenant`). Provenance signing is performed by Tekton Chains in an observer namespace. Release attestation signing occurs strictly within the platform-managed namespace (`managed-tenant`). Builds cannot access release signing material.
- **Trusted Task Verification**: Kyverno admission and Conforma policy rules verify that all pipeline tasks originate from approved, signed, digest-pinned catalogs.
- **Tamper-Resistant Intermediate Artifacts**: Content-addressable OCI storage prevents inter-task data poisoning on shared storage volumes.

---

## Consumer Trust: The VSA as Trust Anchor

Build provenance from Tekton Chains is signed with the build platform's identity — an ephemeral OIDC certificate from Fulcio, or a platform-managed keypair. A consumer who wants to verify the build provenance directly must know and trust that identity, which can change when the platform is upgraded, migrated, or replaced.

The **Verification Summary Attestation (VSA)** solves this through trust delegation:
1. The build pipeline runs in `default-tenant`, producing container images, SBOMs, and Tekton Chains provenance.
2. Upon promotion, the release pipeline runs in `managed-tenant`.
3. The `verify-conforma` task evaluates Enterprise Contract policies against the image and its attestations (checking task trust, digest pinning, CVEs, and SLSA requirements).
4. If policy evaluation passes, the release pipeline distills the conclusions into a signed VSA document:
   - Claims: `verificationResult: PASSED`, `verifiedLevels: [SLSA_BUILD_LEVEL_3]`.
   - Signer: The release platform identity (a stable keypair or a keyless Fulcio certificate with release authority SAN).
5. Consumers verify **one signature** on the VSA against the trusted release platform identity without needing to re-evaluate 100+ raw policy rules or inspect raw Chains provenance.

### The Ambient Release Authority Trap & Dual-Gating

In standard release pipelines, binding release authority to a Kubernetes ServiceAccount introduces an ambient authority trap: any task in `managed-tenant` could sign a VSA prematurely.

To secure this boundary:
- **Model 2 (Dual-Gated Authority — Implemented)**: Kyverno admission and SPIRE enforce that only the final attestation attachment task (`attach-summary-attestations`), running inside the authorized release pipeline (`slsa-e2e-release-dual-gated`), receives the release authority SPIFFE identity. Early tasks possess zero signing identity.
- **Model 3 (Capability Gating — Future Specification)**: Passing `verify-conforma` mints an ephemeral, cryptographically signed policy clearance token tied to the image digest, which must be presented to Fulcio to obtain a release signing certificate.

> For the implementation guide on Model 2 release gating, see **[Dual-Gated Release Guide](dual-gated-release-guide.md)**.

---

## Documentation Index

| Guide | Description |
| :--- | :--- |
| **[Trusting Artifacts](trusting-artifacts.md)** (This Document) | Threat model, OCI Trusted Artifacts, SLSA Build L3, and VSA trust delegation. |
| **[CI Workload Identity Patterns](task-workload-identity-patterns.md)** | The 5 classes of workload identity (push gating, secretless APIs, cloud IAM, separation of duties). |
| **[Dual-Gated Release Guide](dual-gated-release-guide.md)** | Runbook and verification commands for Model 2 managed release authority. |
| **[KubeCon Demo Guide](../demo/README.md)** | Live demonstration guide for KubeCon NA 2026, including slide terminals and setup scripts. |
| **[Part 1: Build and Release](part1-build-and-release.md)** | Walkthrough of onboarding Festoji and achieving SLSA Build L3. |
| **[Part 2: Source Track & Hermetic Builds](part2-source-and-vulnerabilities.md)** | Guide on source verification, hermetic builds, and CVE management. |

---

## References

- [Tekton Chains Documentation](https://tekton.dev/docs/chains/)
- [Type Hinting for SLSA Provenance](https://tekton.dev/docs/chains/slsa-provenance/#type-hinting)
- [Conforma Project](https://conforma.dev)
- [Conforma Policy Rules](https://github.com/conforma/policy)
- [SLSA Specification v1.1](https://slsa.dev/spec/)
- [Verification Summary Attestation (VSA)](https://slsa.dev/verification_summary)
- [Konflux Build Definitions](https://github.com/konflux-ci/build-definitions)
- [ADR 0036: Trusted Artifacts](https://konflux-ci.dev/architecture/ADR/0036-trusted-artifacts.html)
- [ADR 0053: Trusted Task Model](https://github.com/konflux-ci/architecture/blob/main/ADR/0053-trusted-task-model.md)
