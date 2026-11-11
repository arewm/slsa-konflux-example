# "Your CI's Mistaken Identity" — Task-Scoped Trust Demo

Companion repository for the KubeCon NA 2026 talk **"Your CI's Mistaken Identity: Task-Scoped Trust in Cloud-Native Pipelines"** ([slides](https://github.com/arewm/presentations/tree/kubecon-na-2026-finalize-30min/_presentations/2026-11-10-your-cis-mistaken-identity), [session](https://events.linuxfoundation.org/kubecon-cloudnativecon-north-america/program/schedule/?id=1248924)).

This branch (`kubecon-na-2026-your-cis-mistaken-identity`) introduces task-scoped cryptographic workload identities using Tekton, Kyverno, and SPIFFE/SPIRE. It replaces shared ServiceAccount ambient authority with verified, role-scoped machine identities.

## What this builds on

The demo runs on top of the **SLSA end-to-end example**: the Konflux-style build, verification, and release pipeline (SLSA Build Level 3, source track, Conforma policy, VSAs) that is this repository's primary project. That example, its roadmap, tutorials, and stage-by-stage coverage live on the [`main` branch](https://github.com/arewm/slsa-konflux-example/tree/main#readme). This branch extends it with task-scoped identity and will not be merged back.

Each talk pillar has a guide:

- **[Live Demonstration Guide](demo/README.md)**: Interactive terminal walkthrough (Acts 0 through 4), browser slides integration (`ttyd` on ports 7680–7684), clicker support, and setup scripts.
- **Admission-time task verification** (Kyverno classifies TaskRuns by signed, digest-pinned bundle): [CI Workload Identity Patterns](docs/reference/workload-identity-patterns.md) and the policies in [charts/admission-policy/](charts/admission-policy/).
- **Task-scoped SPIFFE/SPIRE identities** (short-lived SVIDs minted from verified task roles): [CI Workload Identity Patterns](docs/reference/workload-identity-patterns.md).
- **Separation of duties in attestations** (Conforma/OPA enforcement of role-scoped claims): [separation_of_duties.rego](demo/manifests/separation_of_duties.rego) and [CI Workload Identity Patterns](docs/reference/workload-identity-patterns.md).
- **OCI push gating and secretless services** (Zot validates SVIDs; Vault exchanges SVIDs for legacy credentials): [Legacy Token Exchange](docs/reference/legacy-token-exchange.md).
- **Dual-gated release authority and label-guard hardening** (Model 2 PipelineRun-scoped release gating): [Dual-Gated Release Guide](docs/reference/dual-gated-release.md).
- **Trusted artifacts and the data plane** (immutable OCI handoffs between tasks): [Trusting Artifacts](docs/reference/trusting-artifacts.md).

---

## Documentation

Hands-on tutorials (build/release, source track, hermetic builds) and technical reference guides (threat models, workload identity patterns, release authority) are indexed in [docs/README.md](docs/README.md).

---

## Prerequisites

Commands in this repository assume execution from the repository root.

Deploy Konflux locally using the official installer:

```bash
# Clone the konflux-ci repository (pinned to tested release v0.2.2)
# The demo cluster was installed with the konflux-operator image
# quay.io/konflux-ci/konflux-operator:release-sha-be0e6ca
# (digest sha256:8d6180cf966ca370938422d2a339cda46d638091238278517bbc46ed75a523b2).
# Pin that digest in your installer for reproducible setups.
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
- Installs Kyverno v1.19.2 (`scripts/install-kyverno.sh`; no longer bundled with Konflux v0.2.2) with internal-registry credentials and the cluster CA bundle.
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
   helm upgrade --install spire ./charts/spiffe-spire -n spire
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
