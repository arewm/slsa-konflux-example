# Trusting Artifacts: Architecture and Threat Model

## The Core Problem: Chains Signs Unverified Outputs

[Tekton Chains](https://tekton.dev/docs/chains/) observes completed PipelineRuns and TaskRuns, generates SLSA provenance attestations, and signs them. This observer pattern keeps signing keys completely out of build containers: the payload does not sign itself.

Because Chains watches the Kubernetes control plane from an observer namespace, its execution record is authoritative. A running task cannot forge Chains' view of what ran: Chains records the task references, source revision, parameters, and timestamps exposed by the Kubernetes control plane.

The limitation lies on the artifact output side. Chains signs whatever artifact references a task reports. It does not verify whether the task is trustworthy, whether the artifact was built from the claimed source, or whether a malicious task simply pulled a pre-built image from an attacker's registry and used Tekton [type hinting](https://tekton.dev/docs/chains/slsa-provenance/#type-hinting) to report it as a build output. When Chains reads that result, it generates cryptographically valid provenance for an artifact that was never built from the claimed source.

Tekton Chains exposes `artifacts.oci.signer: "none"` (tracked in issue [#1346](https://github.com/tektoncd/chains/issues/1346) and PR [#1419](https://github.com/tektoncd/chains/pull/1419)) to disable OCI image signing while retaining in-toto SLSA provenance generation. This prevents Chains from producing misleading cryptographic signatures on unverified container outputs, leaving artifact promotion and release signing to verified gates.

Execution provenance is necessary, but insufficient on its own: release policy must also verify task authorization, artifact integrity, and signing authority.

---

## Task Trust: Evaluating the Execution Record

Because Chains provides an authentic record of what ran, policy engines can evaluate task trust directly against that provenance.

In Konflux, [Conforma](https://conforma.dev) evaluates task trust after the build completes. Its [`trusted_tasks`](https://conforma.dev/docs/policy/packages/release_trusted_task.html) package checks three properties against the Chains-signed provenance:

- Tasks must reference digest-pinned bundles (`@sha256:...`), not mutable tags.
- Those bundles must appear in an approved trusted task catalog.
- Tasks required by policy must themselves be trusted.

If an attacker injects an unauthorized task or replaces a digest with an unpinned tag, Chains records that task reference in the provenance. Conforma detects the violation during policy evaluation and blocks release.

---

## Artifact Trust: Why Task Trust Is Undermined by Shared Volumes

Task trust alone is not sufficient if tasks share a filesystem.

Containers in a Kubernetes pod have separate process and filesystem namespaces. A shared PersistentVolumeClaim (PVC) breaks that isolation by creating an explicit data channel: any container mounting the volume can read or overwrite files left behind by previous tasks.

This forces an all-or-nothing trust model: either *every* task in the pipeline is fully trusted, or *none* of the output can be trusted.

That model creates friction between security teams and developers. If a developer wants to add a custom linter, an experimental test runner, or an inline script, every task that can touch the shared volume must go through catalog review.

### Content-Addressable OCI Artifact Passing

Konflux resolves this tension by replacing PVCs with [Trusted Artifacts](https://konflux-ci.dev/architecture/ADR/0036-trusted-artifacts.html).

Rather than writing to a shared filesystem, tasks package intermediate state into OCI image layers addressed by cryptographic content digest (`sha256:...`). Each task passes its output to the next task through explicit parameter chaining:

1. Task A packages its build outputs, pushes an OCI artifact to storage, and emits the immutable digest.
2. Task B receives that digest as an explicit parameter and unpacks it.
3. If an intermediate file is modified, the digest changes. A downstream task expecting the original digest rejects the modified artifact, breaking the chain.

Because tasks do not share a writable volume, an untrusted task cannot modify intermediate artifacts it never received. Developers can add custom tasks to their pipelines without undermining trust in the core build output.

---

## How This Architecture Supports SLSA Build Level 3

Combining task trust, artifact immutability, isolated signing, and ephemeral pods satisfies the requirements for [SLSA Build Level 3](https://slsa.dev/spec/v1.1/requirements):

- **Ephemeral Execution**: Each build runs in a dedicated Kubernetes pod that is destroyed after completion. No persistent disk or process space is shared across builds.
- **Isolated Signing (Build vs. Release Boundary)**: Build tasks execute in the unprivileged `default-tenant` namespace. Chains signs build provenance from an observer namespace, while release attestations are signed in `managed-tenant`. RBAC prevents tenant workloads from accessing release signing material.
- **Trusted Task Verification**: Conforma policy verifies that all pipeline tasks originate from approved, signed, digest-pinned catalogs.
- **Tamper-Resistant Intermediate Artifacts**: Content-addressable OCI storage prevents inter-task data poisoning on shared storage volumes.

Compromising a single build does not grant access to other builds, cannot forge release signatures, and cannot alter intermediate artifacts without breaking the content-addressed chain.

---

## Consumer Trust: The VSA as Trust Anchor

Build provenance from Tekton Chains is signed with the build platform's identity: an ephemeral signing certificate issued by Fulcio, or a platform-managed keypair. A consumer verifying that provenance directly would have to understand the build platform's internal architecture, track key rotations, and evaluate complex policy rules.

The **Verification Summary Attestation (VSA)** delegates that decision to the release platform:

1. The build pipeline runs in `default-tenant`, producing images and Chains provenance.
2. The release pipeline runs in `managed-tenant`.
3. The `verify-conforma` task evaluates Enterprise Contract policies against the image and its attestations.
4. If verification passes, the release pipeline distills the conclusions into a signed VSA:
   - Claims: `verificationResult: PASSED`, `verifiedLevels: [SLSA_BUILD_LEVEL_3]`.
   - Signer: The release platform identity.
5. Consumers verify a single signature on the VSA against the release platform identity. They do not need to parse the raw build chain or evaluate raw Chains provenance.

---

## Shifting Trust Left: From Retroactive Evaluation to Workload Identity

In the baseline model, Conforma evaluates task trust after the pipeline completes. That model gates releases effectively, but it has limits:
- Untrusted code runs to completion inside the cluster before policy evaluation inspects it.
- Downstream services (registries, internal APIs) cannot easily determine whether a running task is trusted without running a full policy evaluation themselves.

Instead of waiting for a downstream policy engine to evaluate task trust, we can shift that calculation left to **admission time**.

When a `TaskRun` is submitted, an admission controller (Kyverno) verifies that the task bundle is digest-pinned and signed by an approved catalog key *before* the pod is scheduled. Tasks that pass receive a production role; untrusted or inline tasks receive a dev role. SPIRE turns those verified labels into cryptographic workload identities (SPIFFE SVIDs).

This individualizes trust down to specific tasks:
- **Separation of duties**: Scanners sign vulnerability reports, builders sign SBOMs. A builder cannot sign off on a vulnerability scan.
- **Push gating without static secrets**: Registries (like Zot) accept SPIFFE OIDC Bearer tokens, permitting pushes only from vetted builder identities and blocking dev tasks with `403 Forbidden`.
- **Secretless service access**: Internal services validate callers directly against SPIRE's JWKS endpoint without distributing static tokens into tenant namespaces.
- **Dual-gated release authority**: Managed release pipelines prevent ambient authority from signing VSAs before policy evaluation passes.

---

## Related Documentation

- **[CI Workload Identity Patterns](workload-identity-patterns.md)** — The 5 classes of workload identity use cases.
- **[Dual-Gated Release Guide](dual-gated-release.md)** — PipelineRun-scoped release authority in `managed-tenant`.
- **[Live Demonstration Guide](../../demo/README.md)** — Interactive 4-act demonstration for KubeCon NA 2026.
- **[Part 1: Build and Release](../tutorials/part1-build-and-release.md)** — Walkthrough of onboarding Festoji and achieving SLSA Build L3.
- **[Part 2: Source Track & Hermetic Builds](../tutorials/part2-source-and-vulnerabilities.md)** — Guide on source verification, hermetic builds, and CVE management.

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
