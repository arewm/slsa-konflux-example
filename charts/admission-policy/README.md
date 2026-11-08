# Admission Policy Helm Chart

This Helm chart deploys Kyverno ClusterPolicies for Tekton TaskRun and PipelineRun admission classification, OCI bundle signature verification, and label spoofing protection.

## Policies Included

1. **`classify-taskrun`:**
   - Evaluates `TaskRun` creations.
   - Assigns default role label: `trusted-task-role: dev`.
   - If a TaskRun references a bundle that is **digest-pinned** (`@sha256:...`) and matches a pattern in `trustedBundles`, upgrades the label to: `trusted-task-role: prod`.

2. **`prevent-pod-label-spoofing`:**
   - Validates `Pod` creation in tenant and managed namespaces.
   - Enforces that any Pod bearing the `trusted-task-role` label must have an `ownerReference` of kind `TaskRun`.
   - Prevents tenant workloads or rogue pods from self-declaring a trusted role.

3. **`verify-bundle-signatures`:**
   - Requires patched Kyverno controller (with `filter` support on `imageExtractors`).
   - Uses `type: SigstoreBundle` and `imageExtractors` targeting `/spec/taskRef/params/*` (filtered by `bundle`) to locate the OCI task bundle reference.
   - Validates Cosign / Sigstore bundle signatures against configured public keys before admission.

4. **`classify-release-authority`:**
   - Evaluates `TaskRun` creations in the `managed-tenant` namespace.
   - If the task run belongs to the authorized release pipeline (`slsa-e2e-release-dual-gated`), assigns:
     ```yaml
     labels:
       trusted-pipeline-role: release-authority
     ```
   - Used in conjunction with SPIRE `konflux-release-authority` ClusterSPIFFEID to enforce release dual-gating.

## Values Configuration

```yaml
# Trusted bundle patterns with signing keys
trustedBundles:
  - pattern: "registry-service.kind-registry/tekton-catalog/*"
    signingKeys:
      - name: "demo-catalog-key"
        publicKey: |
          -----BEGIN PUBLIC KEY-----
          ...
          -----END PUBLIC KEY-----

# Target namespaces
namespaces:
  - default-tenant
  - managed-tenant
```
