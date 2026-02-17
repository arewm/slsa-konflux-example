# Component Onboarding Helm Chart

Onboard a component/repository to Konflux - install once per component.

## Overview

This chart creates the resources needed for a single component:
- **Application**: Top-level Konflux application resource
- **Component**: Links to a Git repository for building
- **IntegrationTestScenarios**: Two scenarios for policy-driven development
  - `policy-pr`: Validates PR builds at source level 1
  - `policy-push`: Validates push builds with strict policy (matches release)
- **ReleasePlan**: Defines release workflow
- **ReleasePlanAdmission**: Configures release pipeline in managed namespace
- **RoleBinding**: Policy reader permissions for integration service
- **Secret**: (conditional) Pull secret for custom container images

## Prerequisites

- **platform-config chart must be installed first**
- Git repository URL for your component
- GitHub App installed on your repository (for Pipelines as Code)

## Installation

Basic installation:

```bash
helm install myapp ./charts/component-onboarding \
  --set applicationName=myapp \
  --set gitRepoUrl=https://github.com/myorg/myrepo
```

With custom namespaces (must match platform-config):

```bash
helm install myapp ./charts/component-onboarding \
  --set applicationName=myapp \
  --set gitRepoUrl=https://github.com/myorg/myrepo \
  --set namespace=my-tenant \
  --set release.targetNamespace=my-managed-tenant
```

## Required Values

| Value | Description |
|-------|-------------|
| `applicationName` | Name of the application and component |
| `gitRepoUrl` | Git repository URL (e.g., https://github.com/myorg/myrepo) |

## Important Values (Must Match platform-config)

| Value | Default | Description |
|-------|---------|-------------|
| `namespace` | `default-tenant` | Tenant namespace (must match platform-config) |
| `release.targetNamespace` | `managed-tenant` | Managed namespace (must match platform-config) |
| `release.policyName` | `ec-policy` | Policy name (must match platform-config) |
| `release.serviceAccount` | `release-service-account` | ServiceAccount name (must match platform-config) |

## Optional Configuration

### Git Configuration

```yaml
gitRevision: "main"       # Branch to track
gitContext: "."           # Context directory
displayName: "My App"     # Display name (defaults to applicationName)
```

### Container Image

```yaml
containerImage: "registry-service.kind-registry/myapp:latest"
```

Or with custom image requiring authentication:

```yaml
customContainerImage: "quay.io/myorg/myimage:v1.0"
dockerconfigjson: "eyJhdXRocyI6..."  # Base64-encoded .dockerconfigjson
```

### Release Configuration

```yaml
release:
  author: "user1"
  destination: "quay.io/myorg/myapp"  # Defaults to registry-service.kind-registry/released-{applicationName}
  environment: "production"
```

## After Installation

1. Build-service will create a PR in your repository with pipeline definitions
2. Merge the PR to enable builds
3. Open a new PR to trigger the build pipeline

Monitor builds:

```bash
# Watch pipeline runs
kubectl get pipelineruns -n default-tenant -w

# Check integration test scenarios
kubectl get integrationtestscenario -n default-tenant

# View snapshots
kubectl get snapshots -n default-tenant
```

## Integration Test Behavior

**policy-pr** (pull_request context):
- Runs on PR builds
- Validates at source level 1 (PR source branches are not protected)
- Shows whether the push build will succeed

**policy-push** (push context):
- Runs on push-to-main builds
- Validates with strict policy (source level 2+)
- Same policy as release pipeline

## Installing Multiple Components

Each component gets its own installation:

```bash
helm install app1 ./charts/component-onboarding \
  --set applicationName=app1 \
  --set gitRepoUrl=https://github.com/myorg/app1

helm install app2 ./charts/component-onboarding \
  --set applicationName=app2 \
  --set gitRepoUrl=https://github.com/myorg/app2
```

All components share the platform resources (policy, signing keys, service accounts).

## Upgrading

```bash
helm upgrade myapp ./charts/component-onboarding \
  --set applicationName=myapp \
  --set gitRepoUrl=https://github.com/myorg/myrepo
```

## Uninstalling

```bash
helm uninstall myapp
```

This removes the component resources but preserves dynamically created resources like PipelineRuns and Snapshots.
