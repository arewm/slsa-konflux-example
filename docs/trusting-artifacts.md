# Trusting Artifacts: Architecture & Threat Model

## The Core Problem: Chains Signs Anything

[Tekton Chains](https://tekton.dev/docs/chains/) observes completed PipelineRuns and TaskRuns, generates SLSA provenance attestations, and signs them. This observer pattern keeps signing keys completely out of build containers.

The tradeoff is that Chains signs whatever artifacts tasks claim to produce. It doesn't check whether the task is trustworthy, whether the artifact was actually built from the claimed source, or whether a malicious task simply pulled a pre-built image from an attacker's registry and type-hinted it as a build output.

Chains sees a completed task, generates signed SLSA provenance, and signs it. You end up with cryptographically valid provenance for an artifact that was never built from the claimed source.

Signing alone does not solve supply chain security. We need to verify what was signed, who signed it, and whether intermediate artifacts remained intact throughout execution.

---

## Task Trust

The first line of defense is ensuring that tasks in the build pipeline come from approved sources.

In Konflux, [Conforma](https://conforma.dev) evaluates task trust retroactively after the build finishes. Its [`trusted_tasks`](https://conforma.dev/docs/policy/packages/release_trusted_task.html) package checks three things against the build provenance:

- Tasks must reference digest-pinned bundles (`@sha256:...`), not mutable tags
- Those bundles must appear in an approved trusted task list
- Any task that policy declares as required must itself be trusted

If an attacker injects an unauthorized task or points to an unpinned tag, Conforma catches it during policy evaluation and blocks release.

---

## Artifact Trust: Why Task Trust Isn't Sufficient with PVCs

Task trust alone is not enough if your tasks share a volume.

Containers in a Kubernetes pod are isolated from each other, but shared PersistentVolumeClaims (PVCs) break that isolation. When pipeline tasks pass data through a PVC, any task mounted to that volume can read or overwrite files left behind by previous tasks.

That forces an all-or-nothing trust model: either *every* task in the pipeline is fully trusted, or *none* of the output can be trusted.

This creates real friction between security teams and developers. If a developer wants to add a custom linter, an experimental test runner, or an inline script, centralized pipeline ownership means that change has to go through a formal catalog review... just to run a linter.

### Content-Addressable OCI Artifacts

Konflux breaks that all-or-nothing dependency using [Trusted Artifacts](https://konflux-ci.dev/architecture/ADR/0036-trusted-artifacts.html) instead of PVCs.

Rather than writing to a shared filesystem, tasks package intermediate state into OCI image layers addressed by cryptographic content digest (`sha256:...`). Each task's output is passed to the next task through explicit parameter chaining:

1. Task A packages its build outputs, pushes an OCI artifact to storage, and emits the immutable digest.
2. Task B receives that digest as an explicit parameter and unpacks it.
3. If an intermediate file is modified, the digest changes, breaking the chain and failing the build.

Because there is no shared volume, untrusted tasks cannot touch artifacts they were never given. Developers can add custom tasks to their pipelines without undermining trust in the core build output.

---

## How This Achieves SLSA Build Level 3

Combining task trust, artifact immutability, isolated signing, and ephemeral pods satisfies the requirements for [SLSA Build Level 3](https://slsa.dev/spec/v1.1/requirements):

- **Hardened Ephemeral Builds**: Builds run in isolated Kubernetes pods that are torn down after completion. No persistent disk or process space is shared across builds.
- **Isolated Signing (Build vs. Release Boundary)**: Build execution runs in an unprivileged tenant namespace (`default-tenant`). Provenance signing is performed by Tekton Chains in an observer namespace. Release attestation signing occurs strictly within the platform-managed namespace (`managed-tenant`). Builds cannot access release signing material.
- **Trusted Task Verification**: Conforma policy verifies that all pipeline tasks originate from approved, signed, digest-pinned catalogs.
- **Tamper-Resistant Intermediate Artifacts**: Content-addressable OCI storage prevents inter-task data poisoning on shared storage volumes.

An attacker who compromises a single build cannot affect other builds, cannot sign arbitrary artifacts, and cannot tamper with intermediate data without detection.

---

## Consumer Trust: The VSA as Trust Anchor

Build provenance from Tekton Chains is signed with the build platform's identity... an ephemeral OIDC certificate from Fulcio or an internal keypair. A consumer verifying that provenance directly would have to understand the build platform's internals, track key rotations, and reproduce 100+ policy rules.

The **Verification Summary Attestation (VSA)** solves this through trust delegation:

1. The build pipeline runs in `default-tenant`, producing images and Chains provenance.
2. The release pipeline runs in `managed-tenant`.
3. The `verify-conforma` task evaluates Enterprise Contract policies against the image and its attestations.
4. If verification passes, the release pipeline distills the conclusions into a signed VSA:
   - Claims: `verificationResult: PASSED`, `verifiedLevels: [SLSA_BUILD_LEVEL_3]`.
   - Signer: The release platform identity.
5. Consumers verify a single signature on the VSA against the release platform identity. They don't need to parse the raw build chain or understand Tekton Chains internals.

---

## Shifting Trust Left: From Retroactive Policies to Task Identity

In the baseline model, task trust is calculated *retroactively*. Conforma evaluates whether tasks were trusted only after the pipeline completes.

That works fine for gating releases, but it has limits:
- Untrusted code still runs to completion inside the cluster before anything inspects it.
- Outside services (registries, internal APIs) cannot easily know whether a running task is trusted without running a full Conforma policy evaluation themselves.

Instead of waiting for a downstream policy engine to evaluate task trust, we can shift that calculation left to **admission time**.

When a `TaskRun` is submitted, an admission controller (Kyverno) verifies that the task bundle is digest-pinned and signed by an approved catalog key *before* the pod is scheduled. Tasks that pass receive a production role; untrusted or inline tasks receive a dev role. SPIRE turns those verified labels into cryptographic workload identities (SPIFFE SVIDs).

This individualizes trust down to specific tasks:
- **Separation of duties**: Scanners sign vulnerability reports, builders sign SBOMs. A builder cannot sign off on a vulnerability scan.
- **Push gating without static secrets**: Registries (like Zot) accept SPIFFE OIDC Bearer tokens, permitting pushes only from vetted builder identities and blocking dev tasks with `403 Forbidden`.
- **Secretless service access**: Internal services validate callers directly against SPIRE's JWKS endpoint without distributing static tokens into tenant namespaces.
- **Dual-gated release authority**: Managed release pipelines prevent ambient authority from signing VSAs before policy evaluation passes.

For the full taxonomy of workload identity patterns and concrete implementations, see:
- **[CI Workload Identity Patterns](task-workload-identity-patterns.md)** — The 5 classes of workload identity use cases.
- **[Dual-Gated Release Guide](dual-gated-release-guide.md)** — PipelineRun-scoped release authority in `managed-tenant`.
- **[Live Demonstration Guide](../demo/README.md)** — Interactive 4-act demonstration for KubeCon NA 2026.

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
