# Konflux Onboarding Helm Chart

A Helm chart for onboarding applications to Konflux CI with SLSA3 policy verification.

## Overview

This Helm chart creates the necessary Konflux resources to onboard a new application:
- **Application**: The top-level Konflux application resource
- **Component**: A component linked to a Git repository for building
- **IntegrationTestScenario**: A policy-based integration test using Enterprise Contract for SLSA3 verification
- **EnterpriseContractPolicy**: Defines the SLSA3 policy rules for integration and release validation
- **ReleasePlan**: Defines how and where to release the application
- **ReleasePlanAdmission**: Configures the release pipeline to push images to an external registry
- **ServiceAccount**: Service account for release pipeline execution
- **RoleBinding (authenticated-view)**: Grants view permissions to all authenticated users in the managed namespace
- **RoleBinding (release-service-account)**: Grants release permissions to the service account in the managed namespace

## Prerequisites

- Kubernetes cluster with Konflux installed
- Helm 3.x
- A namespace where you want to deploy the resources
- A Git repository URL containing your application code

## Installation

### Basic Usage

Using default namespaces (`user-ns1` for application, `user-ns2` for release):

```bash
helm install my-app ./konflux-onboarding \
  --set applicationName=my-application \
  --set gitRepoUrl=https://github.com/myorg/myrepo
```

Or with custom namespaces:

```bash
helm install my-app ./konflux-onboarding \
  --set applicationName=my-application \
  --set gitRepoUrl=https://github.com/myorg/myrepo \
  --set namespace=my-namespace \
  --set release.targetNamespace=managed-namespace
```

### With Custom Values File

Create a `my-values.yaml` file:

```yaml
applicationName: my-application
gitRepoUrl: https://github.com/myorg/myrepo
namespace: my-namespace
gitRevision: main
displayName: "My Application"
release:
  targetNamespace: managed-namespace
```

Install the chart:

```bash
helm install my-app ./konflux-onboarding -f my-values.yaml
```

## Configuration

### Required Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `applicationName` | Name of the application and component | `my-app` |
| `gitRepoUrl` | Git repository URL for the component | `https://github.com/myorg/myrepo` |

### Optional Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `namespace` | Kubernetes namespace to deploy resources | `user-ns1` |
| `gitRevision` | Git branch/tag to track | `main` |
| `gitContext` | Context directory in the repository | `.` |
| `displayName` | Display name for the application | Same as `applicationName` |
| `containerImage` | Container image for the component | `registry-service.kind-registry/rbean-festoji:latest` |
| `customContainerImage` | Custom container image URL (requires `dockerconfigjson`) | `""` |
| `dockerconfigjson` | Base64-encoded dockerconfigjson for custom image authentication | `""` |
| `release.targetNamespace` | Target namespace for ReleasePlanAdmission and EnterpriseContractPolicy | `user-ns2` |
| `release.destination` | Release destination registry for the component | `registry-service.kind-registry/released-{applicationName}` |
| `release.environment` | Environment name for the release | `production` |
| `release.policyName` | Enterprise Contract policy name for release | `ec-policy` |
| `release.serviceAccount` | Service account for release pipeline | `release-service-account` |

## Resources Created

### 1. Application
Creates a Konflux Application resource that serves as the parent for components.

### 2. Component
Creates a Component that:
- References the Application
- Points to your Git repository
- Triggers builds when code changes

### 3. IntegrationTestScenario (named "policy")
Creates an integration test scenario that:
- Runs the Enterprise Contract pipeline
- References the EnterpriseContractPolicy for SLSA3 validation
- Uses strict policy enforcement
- Runs conformance tests on built images

### 4. EnterpriseContractPolicy (named "example-policy")
Defines the SLSA3 policy for the application:
- **Namespace**: Created in the managed namespace (`release.targetNamespace`)
- **Policy Source**: `github.com/enterprise-contract/config//slsa3`
- **Collections**: Uses the `slsa3` collection of conformance rules
- Referenced by both IntegrationTestScenario and ReleasePlanAdmission

### 5. Secret (conditional)
When using a custom container image, a pull secret is automatically created:
- **Name**: `<applicationName>-pull-secret`
- **Type**: `kubernetes.io/dockerconfigjson`
- Only created when `customContainerImage` is provided

### 6. ReleasePlan
Creates a ReleasePlan that:
- References the Application
- Targets the namespace where ReleasePlanAdmission is located
- Triggers release workflows when builds complete

### 7. ReleasePlanAdmission
Creates a ReleasePlanAdmission that:
- Configures the push-to-external-registry pipeline
- Maps the component to a destination registry
- Uses Enterprise Contract for release policy validation
- Default destination: `registry-service.kind-registry/released-<applicationName>`

### 8. ServiceAccount
Creates a ServiceAccount in the managed namespace:
- **Name**: Configurable via `release.serviceAccount` (default: `release-service-account`)
- Used by the release pipeline for authentication and authorization
- Created in the same namespace as the ReleasePlanAdmission

### 9. RoleBinding (authenticated-view)
Creates a RoleBinding in the managed namespace:
- **Name**: `authenticated-view`
- Grants the `view` ClusterRole to the `system:authenticated` group
- Allows all authenticated users to view resources in the managed namespace

### 10. RoleBinding (release-service-account)
Creates a RoleBinding in the managed namespace:
- **Name**: `{release.serviceAccount}-binding`
- Grants the `release-pipeline-resource-role` ClusterRole to the release service account
- Allows the release pipeline to manage resources in the managed namespace

## Using Custom Container Images

By default, components use the image `registry-service.kind-registry/rbean-festoji:latest`. If you need to use a different container image (e.g., from a private registry), you must provide both `customContainerImage` and `dockerconfigjson`.

### Generating dockerconfigjson

First, create a docker config with your registry credentials:

```bash
# Log in to your registry
docker login registry.example.com

# Get the base64-encoded dockerconfigjson
cat ~/.docker/config.json | base64 -w 0
```

### Example with Custom Image

```bash
# Get your dockerconfigjson
DOCKER_CONFIG=$(cat ~/.docker/config.json | base64 -w 0)

# Install with custom image
helm install my-app ./konflux-onboarding \
  --set applicationName=my-application \
  --set gitRepoUrl=https://github.com/myorg/myrepo \
  --set namespace=my-namespace \
  --set release.targetNamespace=managed-namespace \
  --set customContainerImage=registry.example.com/myorg/myimage:v1.0 \
  --set dockerconfigjson="$DOCKER_CONFIG"
```

Or using a values file:

```yaml
applicationName: my-application
gitRepoUrl: https://github.com/myorg/myrepo
namespace: my-namespace
customContainerImage: registry.example.com/myorg/myimage:v1.0
dockerconfigjson: eyJhdXRocyI6eyJyZWdpc3RyeS5leGFtcGxlLmNvbSI6eyJ1c2VybmFtZSI6InVzZXIiLCJwYXNzd29yZCI6InBhc3MiLCJhdXRoIjoiZFhObGNqcHdZWE56In19fQ==
release:
  targetNamespace: managed-namespace
```

**Note**: When `customContainerImage` is provided, the chart automatically creates a pull secret and references it in the Component spec.

## Configuring Releases

The chart automatically creates ReleasePlan and ReleasePlanAdmission resources to enable automatic releases of your application to an external registry.

The chart uses two separate namespaces by default:
- **Application namespace** (`namespace`): Default is `user-ns1` - where the Application, Component, IntegrationTestScenario, and ReleasePlan are created
- **Managed namespace** (`release.targetNamespace`): Default is `user-ns2` - where the EnterpriseContractPolicy, ReleasePlanAdmission, ServiceAccount, and RoleBindings are created

You can override these defaults as needed for your environment.

### Default Release Behavior

When builds complete successfully and pass integration tests, the release workflow:
1. Validates the build artifacts against Enterprise Contract policies
2. Pushes the component image to the destination registry
3. Default destination: `registry-service.kind-registry/released-<applicationName>`

### Customizing Release Destination

To release to a different registry:

```bash
helm install my-app ./konflux-onboarding \
  --set applicationName=my-application \
  --set gitRepoUrl=https://github.com/myorg/myrepo \
  --set namespace=my-namespace \
  --set release.targetNamespace=managed-namespace \
  --set release.destination=quay.io/myorg/myapp
```

Or in a values file:

```yaml
applicationName: my-application
gitRepoUrl: https://github.com/myorg/myrepo
namespace: my-namespace
release:
  targetNamespace: managed-namespace
  destination: quay.io/myorg/myapp
  environment: production
```

### Using Separate Namespaces

You can deploy the ReleasePlanAdmission to a different "managed" namespace:

```yaml
applicationName: my-application
gitRepoUrl: https://github.com/myorg/myrepo
namespace: dev-namespace
release:
  targetNamespace: managed-release-namespace
  destination: quay.io/myorg/myapp
```

This creates:
- Application, Component, IntegrationTestScenario, ReleasePlan in `dev-namespace`
- EnterpriseContractPolicy, ReleasePlanAdmission, ServiceAccount, RoleBinding in `managed-release-namespace`

## Integration Test Details

The IntegrationTestScenario created by this chart:
- **Name**: `policy`
- **Pipeline**: Uses the Enterprise Contract pipeline from Konflux build-definitions
- **Policy**: References the `example-policy` EnterpriseContractPolicy in the managed namespace
- **Policy Configuration**: `{targetNamespace}/example-policy`
- **Mode**: Strict enforcement (builds will fail if policy violations are found)

The `example-policy` EnterpriseContractPolicy uses:
- **Policy Source**: `github.com/enterprise-contract/config//slsa3`
- **Collections**: `slsa3` (SLSA v0.1 levels 1, 2 & 3 rules plus basic Konflux checks)
- **Data Source**: Acceptable Tekton bundles from `quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles`

## Example: Complete Deployment

```bash
# Create or use an existing namespace
kubectl create namespace my-app-dev

# Install the chart
helm install my-application ./konflux-onboarding \
  --set applicationName=my-application \
  --set gitRepoUrl=https://github.com/myorg/myrepo \
  --set namespace=my-app-dev \
  --set release.targetNamespace=my-app-managed \
  --set gitRevision=develop \
  --set displayName="My Application"

# Verify resources were created
kubectl get applications,components,integrationtestscenarios,releaseplans,releaseplanadmissions -n my-app-dev
```

## Uninstalling

```bash
helm uninstall my-app
```

Note: This will remove the Helm release but may not delete all Konflux-generated resources. You may need to manually clean up builds, snapshots, and other dynamically created resources.

## Customization

### Using a Different Policy

To use a different Enterprise Contract policy, you can modify the EnterpriseContractPolicy after deployment:

```bash
kubectl edit enterprisecontractpolicy example-policy -n managed-namespace
```

You can modify:
- `spec.sources[].policy`: Change the policy source URL
- `spec.configuration.collections`: Change the collection (e.g., from `slsa3` to another collection)
- `spec.configuration.include/exclude`: Add or remove specific policy rules

### Adding Multiple Components

This chart creates a single component. For multiple components in the same application, you can:
1. Install the chart multiple times with different component names
2. Create a custom values file with component arrays
3. Manually create additional Component resources

## Troubleshooting

### Check Application Status
```bash
kubectl get application my-application -n my-namespace -o yaml
```

### Check Component Status
```bash
kubectl get component my-application -n my-namespace -o yaml
```

### Check Integration Test Status
```bash
kubectl get integrationtestscenario policy -n my-namespace -o yaml
```

### Check EnterpriseContractPolicy Status
```bash
# Check in the managed namespace
kubectl get enterprisecontractpolicy example-policy -n managed-namespace -o yaml
```

### Check ReleasePlan Status
```bash
kubectl get releaseplan my-application-release -n my-namespace -o yaml
```

### Check ReleasePlanAdmission Status
```bash
# Check in the target namespace (may be different from application namespace)
kubectl get releaseplanadmission my-application-release-admission -n my-namespace -o yaml
```

### View Release Status
```bash
# List all releases for your application
kubectl get releases -n my-namespace

# View details of a specific release
kubectl get release <release-name> -n my-namespace -o yaml
```

### View Build Logs
```bash
# List pipeline runs
kubectl get pipelineruns -n my-namespace

# View logs for a specific pipeline run
kubectl logs -n my-namespace pipelinerun/<pipelinerun-name> --all-containers
```

## License

This Helm chart is provided as-is for use with Konflux CI.

## Contributing

Issues and pull requests are welcome.
