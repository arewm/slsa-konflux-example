# Trusting Artifacts

## The Core Problem: Chains Signs Anything

[Tekton Chains](https://tekton.dev/docs/chains/) automatically observes completed PipelineRuns and TaskRuns, generates SLSA provenance attestations, and signs them. This powerful observer pattern ensures signing keys remain separate from build execution.

This architecture, however, means that Chains will sign whatever artifacts tasks and pipelines claim to have produced, without verifying:
- Whether the task itself is trustworthy
- Whether the artifacts were actually built in this pipeline
- Whether a malicious task substituted pre-built artifacts

For example, a malicious task could:
1. Claim to build a container image from source
2. Actually pull a pre-compromised image from an attacker's registry
3. Use Tekton [type hinting](https://tekton.dev/docs/chains/slsa-provenance/#type-hinting) to report this as a "built" artifact
4. Chains observes the completed task and generates signed SLSA provenance
5. **Result**: Signed provenance for a malicious artifact that was never actually built

The provenance would be cryptographically valid and claim the artifact was built from trusted source code, when in reality it was substituted.

## The Solution: Verify Tasks AND Artifacts

To trust the provenance, we must trust the entire build chain:

1. **Verify Tasks Are Trusted**: Ensure all tasks come from known, approved sources
2. **Prevent Artifact Tampering**: Ensure artifacts can't be modified between tasks
3. **Generate Provenance**: Tekton Chains creates signed attestations of what was built
4. **Policy Evaluation**: Verify the complete build chain before release

## Task Trust: Why It Matters

Konflux leverages [Conforma](https://conforma.dev) to establish a process for verifying trust in tasks.

- Tasks must reference digest-pinned task bundles (not mutable tags)
- Task bundles must be in an approved trusted task list
- If any tasks are required in a policy, those MUST also be trusted

Conforma has a [`trusted_tasks`](https://conforma.dev/docs/policy/packages/release_trusted_task.html) package which includes all relevant policy rules for establishing this trust.

## Artifact Trust: Preventing Tampering

While the orchestrated containers are isolated from each other, any shared volume used to transfer data between tasks is a cache which needs to be appropriately protected as well. This means that any untrusted task could compromise the entire build process.

When a pipeline is using shared storage (PVCs) between tasks:
- **ALL tasks must be trusted** because any task can modify shared artifacts
- A single malicious task can tamper with artifacts from previous tasks
- No cryptographic verification prevents this tampering
- Trust boundaries cannot be scoped to individual tasks

While this works, it hampers user experience as it reduces the ability to have a decentralized pipeline ownership. Any change, no matter how specific, would need to go through a centralized process to become trusted. In Konflux, however, we leverage [Trusted Artifacts](https://konflux-ci.dev/architecture/ADR/0036-trusted-artifacts.html) by default for transferring data between tasks instead of PVCs.

This prevents tampering by:
- Eliminating shared mutable storage between tasks
- Storing artifacts as immutable OCI images (content-addressable by digest) and loading that content in future tasks
- Explicitly chaining dependencies using results of one task and params of another
- Enabling selective trust based on artifact dependencies

**Key advantage**: With immutable artifact storage, we enable users to customize their pipeline without affecting our trust in the resulting artifacts.

## References

### Tekton and Chains
- [Tekton Chains Documentation](https://tekton.dev/docs/chains/)
- [Type Hinting for SLSA Provenance](https://tekton.dev/docs/chains/slsa-provenance/#type-hinting)

### Conforma (Enterprise Contract)
- [Conforma Project](https://conforma.dev)
- [EC Policies Repository](https://github.com/conforma/policy)

### SLSA
- [SLSA Specification](https://slsa.dev/spec/)
- [Verification Summary Attestation (VSA)](https://slsa.dev/verification_summary)

### Konflux
- [Build Definitions Repository](https://github.com/konflux-ci/build-definitions)