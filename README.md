# SLSA End-to-End Example (Konflux style)

This repository demonstrates how to achieve end-to-end SLSA (Supply-chain Levels for Software Artifacts) compliance using [Konflux](https://konflux-ci.dev).
It is created in response to the SLSA [request for examples](https://slsa.dev/blog/2025/07/slsa-e2e).

If you are not familiar with Konflux, it is an open source, cloud-native software factory focused on software supply chain security. Developers need flexibility to build software quickly; security teams need controls to prevent supply chain attacks. Konflux hardens the platform to achieve SLSA Build L3 by default, giving developers flexibility to build what they need while ensuring security requirements are met before artifacts leave their control.

### SLSA E2E Stage Coverage

| Stage | Coverage | SLSA Level | Key Components |
|-------|----------|------------|----------------|
| Source | Covered | L2-L3 (via source-tool) | `verify-source` task, `slsa_source_verification.rego` |
| Build | Covered | L3 (Tekton Chains) | `slsa-e2e-oci-ta` pipeline, pod isolation, namespace separation |
| Verification | Covered | Conforma + custom policies | `verify-conforma`, `attach-vsa`, `rule_data.yml` |
| Publication | Covered | Pipeline-gated | `push-snapshot` gated by `verify-conforma` |
| Use | Covered | OCI-native VSA distribution | `cosign verify-attestation` |

## Walkthroughs

The repository is organized into two walkthroughs that build on each other:

**[Part 1: Build and Release](docs/part1-build-and-release.md)** covers the fundamentals using Festoji as a simple example component. You will onboard a component, understand how Konflux achieves SLSA Build L3, inspect build artifacts (SBOM, provenance, signatures), run integration tests, release with policy enforcement, and verify artifacts as a consumer.

**[Part 2: Source Track, Vulnerability Management, and Hermetic Builds](docs/part2-source-and-vulnerabilities.md)** introduces advanced topics using source-test-repo as an example. It covers SLSA Source Track L3 via source-tool enrollment, per-application Enterprise Contract policies, CVE management (leeway, per-CVE exceptions, volatile configuration), and hermetic builds for reproducibility.

For the threat model behind trusted tasks, artifact immutability, and signing key isolation, see [Trusting Artifacts](docs/trusting-artifacts.md).

## Pre-requisites

All commands in this guide assume you are in the root directory of the slsa-konflux-example repository unless otherwise specified.

To explore SLSA with Konflux, you need a running instance. The simplest way is the [konflux-ci](https://github.com/konflux-ci/konflux-ci) deployment script:

```bash
# Clone the konflux-ci repository (pinned to tested release)
git clone --branch v0.4 https://github.com/konflux-ci/konflux-ci.git
cd konflux-ci

# The Konflux operator now requires a configuration file
cp scripts/deploy-local.env.template scripts/deploy-local.env
# Edit deploy-local.env with your GitHub App credentials

# Deploy Konflux operator
./scripts/deploy-local.sh
```

**Tested with:** konflux-ci/konflux-ci v0.4

This script creates a Kind cluster, deploys the Konflux operator, creates the `default-tenant` namespace with demo users (user1@konflux.dev, user2@konflux.dev), and configures webhooks for Pipelines as Code.

After deploying the operator, run the prerequisites script:

```bash
cd /path/to/slsa-konflux-example
./scripts/setup-prerequisites.sh
```

The prerequisites script creates the `managed-tenant` namespace for privileged release operations and applies custom SLSA pipeline configuration to the build service.

For detailed deployment options, see the [Operator Deployment Guide](https://github.com/konflux-ci/konflux-ci/blob/main/docs/operator-deployment.md).

### Required Tools

Install these CLI tools for the demo: [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl) for cluster interaction, [cosign](https://github.com/sigstore/cosign?tab=readme-ov-file#installation) for inspecting OCI artifact attestations, [helm](https://github.com/helm/helm?tab=readme-ov-file#install) for deploying resources to the Kind cluster, [tkn](https://github.com/tektoncd/cli?tab=readme-ov-file#installing-tkn) for viewing Tekton pipelines, and optionally [gh](https://cli.github.com/) for GitHub CLI operations.

**NOTE:** Save your Pipelines as Code GitHub App URL after creating it. You need it to configure your repository.

### Demo Authentication

The Konflux operator automatically configures demo users:

- **user1@konflux.dev** / `password` - Admin access to `default-tenant`
- **user2@konflux.dev** / `password` - Admin access to `managed-tenant`

**WARNING:** These are insecure demo credentials for testing only. For production deployments, configure proper authentication using the [Demo Users Configuration Guide](https://github.com/konflux-ci/konflux-ci/blob/main/docs/demo-users.md).

### Accessing the Konflux UI

After you deploy Konflux, view pipeline runs and builds in the Konflux web UI at https://localhost:9443

### Accessing the Kind Cluster Registry

This demo uses the internal Kind registry by default. For complete registry configuration options (including external registries like Quay.io), see [Registry Configuration](https://github.com/konflux-ci/konflux-ci/blob/main/docs/registry-configuration.md).

The internal registry is accessible at:
- From host: `localhost:5001`
- Within cluster: `registry-service.kind-registry.svc.cluster.local`

## Workflow Overview

Konflux separates builds and releases into distinct trust boundaries to prevent unauthorized artifact signing (see [Trusting Artifacts](docs/trusting-artifacts.md) for the threat model). When you onboard a component, build-service creates a pull request in your repository with Tekton pipeline definitions. Merging that PR enables the automated workflow.

Builds run in an unprivileged tenant namespace where signing keys are absent. After a build completes, Tekton Chains generates SLSA provenance and signs the artifacts. Integration tests validate the build against policies. When you merge to the main branch, the release pipeline runs in a privileged managed namespace where Conforma performs final policy validation before promoting images to the release registry.

## Helm Charts

This repository provides two helm charts:

**platform-config** installs once per cluster to establish trust boundaries, signing keys, and policies. It creates the EnterpriseContractPolicy for SLSA3 validation, RoleBindings for admin access, ServiceAccounts for release pipeline execution, and signing keys for release attestation signing.

```bash
helm install platform ./charts/platform-config
```

**component-onboarding** installs once per component to create the application, integration tests, and release plan.

```bash
export FORK_ORG="ORGANIZATION"
helm install festoji ./charts/component-onboarding \
  --set applicationName=festoji \
  --set gitRepoUrl=https://github.com/${FORK_ORG}/festoji
```

Both charts operate across two namespaces:

- `default-tenant`: The unprivileged tenant namespace where builds occur (created by the Konflux operator)
- `managed-tenant`: The privileged managed namespace where releases are validated and signed (created by the prerequisites script)

Namespace values default to `default-tenant` and `managed-tenant`. If you override them, values must match between platform-config and component-onboarding.

See the chart `values.yaml` files for all configuration options:
- [`charts/platform-config/values.yaml`](charts/platform-config/values.yaml)
- [`charts/component-onboarding/values.yaml`](charts/component-onboarding/values.yaml)

## Tips

**Recovering kubeconfig:** If you lose your kubeconfig connection to the Kind cluster:
```bash
kind export kubeconfig -n konflux
```

**Freeing cluster resources:** Kind clusters have limited resources. Completed and failed PipelineRuns retain pods and volume claims that consume memory. If tasks fail with `ExceededNodeResources`, clean up old runs:
```bash
# Delete completed/failed PipelineRuns in both namespaces
kubectl delete pipelineruns -n default-tenant --field-selector=status.conditions[0].reason!=Running
kubectl delete pipelineruns -n managed-tenant --field-selector=status.conditions[0].reason!=Running
```

For more troubleshooting, see [Troubleshooting Guide](https://github.com/konflux-ci/konflux-ci/blob/main/docs/troubleshooting.md).

## Additional Resources

- [Konflux Documentation](https://konflux-ci.dev/docs/) - Complete platform documentation
- [SLSA Specification](https://slsa.dev/spec/) - Supply-chain security framework
- [Conforma Policy Engine](https://conforma.dev) - Policy validation and enforcement
- [Tekton Chains](https://tekton.dev/docs/chains/) - Artifact signing and provenance
- [Trusting Artifacts](docs/trusting-artifacts.md) - Threat model for build trust
