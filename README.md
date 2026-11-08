# SLSA End-to-End Example (Konflux style)

This repository demonstrates end-to-end SLSA (Supply-chain Levels for Software Artifacts) compliance using [Konflux](https://konflux-ci.dev), Tekton, Kyverno, and SPIFFE/SPIRE. It hardens build platforms to achieve SLSA Build Level 3 by default while eliminating ambient authority across the pipeline.

### SLSA E2E Stage Coverage

| Stage | Coverage | SLSA Level | Key Components |
|---|---|---|---|
| Source | Covered | L2-L3 (via source-tool) | `verify-source` task, `slsa_source_verification.rego` |
| Build | Covered | L3 (Tekton Chains) | `slsa-e2e-oci-ta` pipeline, pod isolation, namespace separation |
| Verification | Covered | Conforma policy evaluation | `verify-conforma`, `rule_data.yml` |
| Publication | Covered | Pipeline-gated | `push-snapshot` gated by `verify-conforma` |
| Use | Covered | OCI-native VSA distribution | `cosign verify-attestation` |

---

## Documentation Roadmap

The documentation is organized into hands-on tutorials and technical reference guides:

### Hands-On Tutorials
- **[Part 1: Build and Release](docs/tutorials/part1-build-and-release.md)**: Onboard Festoji, build containers with pod isolation, inspect OCI 1.1 referrers (SBOM, provenance, signatures), and verify releases as a consumer.
- **[Part 2: Source Track, Vulnerability Management, and Hermetic Builds](docs/tutorials/part2-source-and-vulnerabilities.md)**: Advanced controls with `source-test-repo`: Source Level 3 via `source-tool`, per-application Conforma policies, CVE leeway, and hermetic builds.

### Technical Reference & Threat Models
- **[Trusting Artifacts: Architecture & Threat Model](docs/reference/trusting-artifacts.md)**: Why Tekton Chains signs unverified outputs, why PersistentVolumeClaims undermine task trust, how OCI Trusted Artifacts enforce immutability, and how Verification Summary Attestations (VSAs) delegate consumer trust.
- **[CI Workload Identity Patterns](docs/reference/workload-identity-patterns.md)**: Taxonomy of five production patterns: separation of duties in attestation signing, federated OCI push gating, secretless internal APIs, cloud IAM federation, and release boundary capability gating.
- **[Dual-Gated Release Authority Guide](docs/reference/dual-gated-release.md)**: Implementation runbook for Model 2 release gating in `managed-tenant`.
- **[Documentation Index](docs/README.md)**: Complete guide directory.

---

## KubeCon NA 2026: "Your CI's Mistaken Identity"

This branch (`kubecon-na-2026-your-cis-mistaken-identity`) introduces **task-scoped cryptographic workload identities** using Tekton, Kyverno, and SPIFFE/SPIRE. It replaces shared ServiceAccount ambient authority with verified, role-scoped machine identities.

- **[Live Demonstration Guide](demo/README.md)**: Interactive terminal walkthrough (Acts 0 through 4), browser slides integration (`ttyd` on ports 7680–7684), clicker support, and setup scripts.
- **[CI Workload Identity Patterns](docs/reference/workload-identity-patterns.md)**: The 5 production workload identity patterns.
- **[Dual-Gated Release Guide](docs/reference/dual-gated-release.md)**: Model 2 PipelineRun-scoped release dual-gating.

---

## Prerequisites

Commands in this repository assume execution from the repository root.

Deploy Konflux locally using the official installer:

```bash
# Clone the konflux-ci repository (pinned to tested release v0.2.2)
export KONFLUX_VERSION=v0.2.2
git clone --branch "${KONFLUX_VERSION}" https://github.com/konflux-ci/konflux-ci.git
cd konflux-ci

cp scripts/deploy-local.env.template scripts/deploy-local.env
# Configure deploy-local.env with GitHub App credentials

OPERATOR_INSTALL_METHOD=release OPERATOR_RELEASE="${KONFLUX_VERSION}" \
  ./scripts/deploy-local.sh
```

Deploy the in-cluster Sigstore stack (Fulcio, Rekor, CT Log, TUF):

```bash
# On amd64 hosts:
./integrations/sigstore/install.sh

# On arm64 hosts (Apple Silicon, AWS Graviton):
./integrations/sigstore/install.sh \
  --extra-values-file /path/to/slsa-konflux-example/integrations/sigstore/values-arm64.yaml
```

Run the repository prerequisites script:

```bash
cd /path/to/slsa-konflux-example
./scripts/setup-prerequisites.sh
```

The prerequisites script:
- Creates the `managed-tenant` namespace for release operations.
- Configures the Konflux operator to use the custom SLSA pipeline (`slsa-e2e-oci-ta`).
- Configures Tekton Chains for OCI 1.1 Referrers (`sigstore-bundle` format) and keyless Fulcio/Rekor signing.
- Distributes internal registry credentials to build and release ServiceAccounts.

### Required CLI Tools
Install: [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl), [cosign](https://github.com/sigstore/cosign), [helm](https://helm.sh/), [tkn](https://github.com/tektoncd/cli), [jq](https://jqlang.github.io/jq/), [yq](https://github.com/mikefarah/yq), [skopeo](https://github.com/containers/skopeo), [oras](https://oras.land/), and [podman](https://podman.io/).

### Accessing Endpoints
- **Konflux Web UI**: `https://localhost:9443` (Log in with `user1@konflux.dev` / `password` for `default-tenant`, or `user2@konflux.dev` / `password` for `managed-tenant`).
- **Internal Kind Registry**: `localhost:5001` (external) or `registry-service.kind-registry.svc.cluster.local` (in-cluster).

---

## Helm Charts

This repository provides four Helm charts:

1. **`platform-config`**: Establishes cluster-wide trust boundaries, EnterpriseContractPolicies, and release ServiceAccounts.
   ```bash
   helm upgrade --install platform ./charts/platform-config
   ```
2. **`admission-policy`**: Deploys Kyverno policies for admission-time bundle signature checking, digest pinning enforcement, role labeling (`dev` vs. `prod`), and pod label spoofing prevention.
   ```bash
   helm upgrade --install admission-policy ./charts/admission-policy
   ```
3. **`spiffe-spire`**: Deploys SPIRE identity infrastructure (Server, Agent DaemonSet, SPIFFE CSI driver, OIDC Discovery Provider) and configures `ClusterSPIFFEID` custom resources.
   ```bash
   helm upgrade --install spiffe-spire ./charts/spiffe-spire
   ```
4. **`component-onboarding`**: Onboards an application component, creating Application, Component, IntegrationTestScenario, and ReleasePlan resources.
   ```bash
   export FORK_ORG="ORGANIZATION"
   helm upgrade --install festoji ./charts/component-onboarding \
     --set componentName=festoji \
     --set gitRepoUrl=https://github.com/${FORK_ORG}/festoji
   ```

Chart configurations are detailed in:
- [`charts/platform-config/values.yaml`](charts/platform-config/values.yaml)
- [`charts/admission-policy/values.yaml`](charts/admission-policy/values.yaml)
- [`charts/spiffe-spire/values.yaml`](charts/spiffe-spire/values.yaml)
- [`charts/component-onboarding/values.yaml`](charts/component-onboarding/values.yaml)

---

## Troubleshooting

- **Recover kubeconfig**:
  ```bash
  kind export kubeconfig -n konflux
  ```
- **Free cluster resources**: Completed and failed PipelineRuns retain pods and PVCs:
  ```bash
  kubectl delete pipelineruns -n default-tenant --field-selector=status.conditions[0].reason!=Running
  kubectl delete pipelineruns -n managed-tenant --field-selector=status.conditions[0].reason!=Running
  ```

---

## Additional Resources

- [Konflux Platform Documentation](https://konflux-ci.dev/docs/)
- [SLSA Specification v1.1](https://slsa.dev/spec/)
- [Conforma Policy Engine](https://conforma.dev)
- [Tekton Chains Documentation](https://tekton.dev/docs/chains/)
- [Documentation Index](docs/README.md)
