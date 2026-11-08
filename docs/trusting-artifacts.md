# Trusting Artifacts

## The Core Problem: Chains Signs Anything

[Tekton Chains](https://tekton.dev/docs/chains/) observes completed PipelineRuns and TaskRuns, generates SLSA provenance attestations, and signs them. This observer pattern keeps signing keys separate from build execution.

The tradeoff is that Chains signs whatever artifacts tasks claim to produce. It does not verify whether the task is trustworthy, whether the artifact was actually built in this pipeline, or whether a malicious task swapped in a pre-built image.

Consider what happens when a malicious task enters the pipeline. It claims to build a container image from source, but instead pulls a pre-compromised image from an attacker's registry. It uses Tekton [type hinting](https://tekton.dev/docs/chains/slsa-provenance/#type-hinting) to report this as a "built" artifact. Chains sees a completed task, generates signed SLSA provenance, and now you have cryptographically valid provenance for an artifact that was never actually built from the claimed source.

Signing alone does not solve supply chain security. We need to verify what was signed.

## The Solution: Verify Tasks AND Artifacts

Trusting provenance requires trusting the entire build chain. All tasks must come from known, approved sources, and artifacts must remain immutable between tasks.

Konflux enforces both properties at different stages. During the build, Tekton Chains creates signed attestations recording what happened. At release time, the `verify-conforma` task in the managed namespace checks the attestations against policy: Were the tasks trusted? Are the artifacts intact? Only after validation passes does the release pipeline promote images.

## Task Trust

Konflux uses [Conforma](https://conforma.dev) to verify that every task in a build came from an approved source.

Conforma's [`trusted_tasks`](https://conforma.dev/docs/policy/packages/release_trusted_task.html) package enforces three requirements:

- Tasks must reference digest-pinned bundles, not mutable tags
- Those bundles must appear in an approved trusted task list
- Any task that a policy declares as required must itself be trusted

## Artifact Trust: Why PVCs Are Not Enough

Containers in a pipeline are isolated from each other, but shared volumes tell a different story. When tasks pass data through PVCs, any task with access to the volume can read or modify artifacts left by previous tasks. A single malicious task can tamper with everything. This forces an all-or-nothing trust model: either every task in the pipeline is trusted, or none of the output can be trusted.

That model works, but it has a real cost. Centralized pipeline ownership means every change, even adding a linter, must go through a trust review process. This tension between security and developer autonomy is why Konflux uses [Trusted Artifacts](https://konflux-ci.dev/architecture/ADR/0036-trusted-artifacts.html) instead of PVCs.

Trusted Artifacts store intermediate data as immutable OCI images, addressed by content digest. Rather than writing to a shared filesystem, each task's output becomes the next task's input through explicit parameter chaining.

This design makes tampering detectable: any modification changes the digest. It also scopes trust more narrowly. Because there is no shared volume, untrusted tasks cannot modify artifacts they never receive. Users can add custom tasks to their pipeline without undermining trust in the build output.

## How This Achieves SLSA Build L3

The properties above — task trust verification, artifact immutability, and signing key isolation — are the building blocks of [SLSA Build Level 3](https://slsa.dev/spec/v1.1/requirements). Specifically:

**Hardened builds.** Each build runs in an isolated Kubernetes pod. Pods are ephemeral and do not share state with other builds. The build environment is defined by the pipeline and task definitions, not by ad-hoc commands.

**Isolated signing.** Tekton Chains signs provenance in an observer namespace. The signing key is never accessible to the build pipeline. A compromised build cannot forge provenance for a different artifact.

**Trusted task verification.** At release time, Conforma verifies that every task in the build came from an approved, digest-pinned bundle. This prevents a compromised pipeline from injecting unauthorized tasks that could exfiltrate secrets or swap artifacts.

**Tamper-resistant artifacts.** Trusted Artifacts use content-addressable OCI storage between tasks. Any modification to intermediate artifacts changes the digest, breaking the chain and causing verification to fail.

Together, these properties mean that an attacker who compromises a single build cannot affect other builds, cannot sign arbitrary artifacts, and cannot inject untrusted tasks without detection. This is the core guarantee of SLSA Build L3.

For a walkthrough of these properties in practice, see [Part 1: Build and Release](part1-build-and-release.md).

## Consumer Trust: The VSA as Trust Anchor

Build provenance from Tekton Chains is signed with the build platform's identity — an ephemeral OIDC certificate from Fulcio, or a platform-managed keypair on clusters without Sigstore. A consumer who wants to verify the build provenance directly must know and trust that identity, which can change when the platform is upgraded, migrated, or replaced.

The Verification Summary Attestation solves this. Rather than asking consumers to verify the full build chain themselves, the release pipeline runs Conforma against the build provenance, distills the conclusions into a new VSA document, and signs it using the release signing key — a separate, stable identity controlled by the release platform and distributed out-of-band to consumers (for example, included in a project's security documentation or pinned in a trust policy).

This is trust delegation: the release platform (known, stable key) vouches that it ran the full policy evaluation against the build provenance. Consumers verify one signature against one key and receive the SLSA level claims without needing to:

- Know the build platform's signing identity or certificate issuance details
- Understand how Tekton Chains signs provenance
- Reproduce the full policy evaluation

The tradeoff is explicit: consumers trust that Conforma's evaluation was correct and that the release platform is trustworthy. The VSA is a receipt, not an independent proof — its value depends on the release platform running meaningful policy in an integrity-controlled environment. This is why the release pipeline runs in the managed namespace where platform operators, not developers, control policy and signing keys.

## References

- [Tekton Chains Documentation](https://tekton.dev/docs/chains/)
- [Type Hinting for SLSA Provenance](https://tekton.dev/docs/chains/slsa-provenance/#type-hinting)
- [Conforma Project](https://conforma.dev)
- [Conforma Policy Rules](https://github.com/conforma/policy)
- [SLSA Specification](https://slsa.dev/spec/)
- [Verification Summary Attestation (VSA)](https://slsa.dev/verification_summary)
- [Konflux Build Definitions](https://github.com/konflux-ci/build-definitions)
