# git-clone-slsa

A Tekton task that clones a Git repository and performs SLSA (Supply-chain Levels for Software Artifacts) source verification, storing both the source code and SLSA attestations as trusted artifacts.

## Description

This task extends the standard `git-clone-oci-ta` functionality with SLSA source track verification capabilities. It:

1. **Clones the repository** using the same proven logic as `git-clone-oci-ta`
2. **Verifies SLSA source attestations** using the [slsa-framework/source-tool](https://github.com/slsa-framework/source-tool)
3. **Generates Verification Summary Attestations (VSA)** documenting the achieved SLSA level
4. **Stores artifacts securely** in OCI-compatible trusted artifact storage

## Key Features

- **Always generates attestations**: Even repositories without explicit SLSA configuration receive basic level 1 verification
- **Policy-driven verification**: Uses external policy repositories to define SLSA requirements
- **Comprehensive reporting**: Provides detailed test-like results following Tekton conventions
- **Trust boundary compliance**: Separates source verification (tenant context) from signing (managed context)
- **Backward compatibility**: Drop-in replacement for `git-clone-oci-ta` with additional SLSA capabilities

## Parameters

### Standard Git Parameters
All parameters from `git-clone-oci-ta` are supported:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `url` | Repository URL to clone | (required) |
| `revision` | Revision to checkout (branch, tag, sha, ref) | `""` |
| `ociStorage` | OCI repository for trusted artifacts | (required) |
| `depth` | Shallow clone depth | `"1"` |
| `submodules` | Initialize git submodules | `"true"` |
| `fetchTags` | Fetch all tags | `"false"` |

### SLSA-Specific Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `slsaPolicyRepo` | Repository containing SLSA policies | `"https://github.com/slsa-framework/source-policies"` |
| `slsaMinimumLevel` | Minimum required SLSA level | `"SLSA_SOURCE_LEVEL_1"` |
| `slsaFailOnPolicyMissing` | Fail if no policy found | `"false"` |

## Workspaces

| Workspace | Description | Required |
|-----------|-------------|----------|
| `basic-auth` | Git credentials (username/password) | No |
| `ssh-directory` | SSH keys for git authentication | No |

## Results

### Standard Git Results
All results from `git-clone-oci-ta` are provided:

| Result | Description |
|--------|-------------|
| `SOURCE_ARTIFACT` | Trusted artifact URI for source code |
| `commit` | Precise commit SHA |
| `url` | Repository URL |
| `CHAINS-GIT_COMMIT` | Chains-compatible commit SHA |
| `CHAINS-GIT_URL` | Chains-compatible repository URL |

### SLSA-Specific Results

| Result | Description |
|--------|-------------|
| `SLSA_VSA_ARTIFACT` | Trusted artifact URI containing VSA and attestations |
| `SLSA_LEVEL_ACHIEVED` | Actual SLSA level verified (e.g., "SLSA_SOURCE_LEVEL_2") |
| `TEST_OUTPUT` | JSON test results following Tekton test conventions |

## SLSA Levels

The task can verify repositories at different SLSA source track levels:

### SLSA_SOURCE_LEVEL_1 (Default)
- Basic git integrity verification
- Always achievable for any Git repository
- Generates minimal VSA documenting source state

### SLSA_SOURCE_LEVEL_2
- Requires branch protection with:
  - Deletion prevention (`deletion` rule)
  - Non-fast-forward prevention (`non_fast_forward` rule)
- Policy configuration in the policy repository

### SLSA_SOURCE_LEVEL_3
- All Level 2 requirements plus:
- Two-party review (pull request approval)
- Required status checks
- Tag hygiene controls

## Usage Example

```yaml
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: clone-with-slsa
spec:
  taskRef:
    name: git-clone-slsa
  params:
    - name: url
      value: "https://github.com/example/repo"
    - name: ociStorage
      value: "quay.io/example/trusted-artifacts"
    - name: slsaMinimumLevel
      value: "SLSA_SOURCE_LEVEL_2"
  workspaces:
    - name: ssh-directory
      secret:
        secretName: git-ssh-key
```

## Integration with Konflux Pipelines

This task is designed for use in Konflux tenant-context pipelines where source verification must occur before build processes. The generated attestations can be consumed by downstream managed-context tasks for policy evaluation and signing.

### Typical Pipeline Flow

1. **git-clone-slsa** (tenant context) - Clone and verify source
2. **build-task** (tenant context) - Build application using verified source
3. **conforma-vsa** (managed context) - Evaluate policies using SLSA attestations
4. **vsa-sign** (managed context) - Sign and publish final attestations

## Policy Configuration

The task uses external policy repositories to define SLSA requirements. Policies are JSON files organized by repository:

```
policy/github.com/
├── example/
│   └── repo/
│       └── source-policy.json
```

Example policy:
```json
{
  "canonical_repo": "https://github.com/example/repo",
  "protected_branches": [
    {
      "Name": "main",
      "Since": "2024-01-01T00:00:00Z",
      "target_slsa_source_level": "SLSA_SOURCE_LEVEL_2"
    }
  ]
}
```

## Building the Container Image

The task requires a custom container image built from the included Containerfile:

```bash
# Copy source-tool source code to the build context
cp -r .internal/repositories/source-tool .

# Build the image
podman build -f tenant-context/tasks/git-clone-slsa/0.1/Containerfile \
  -t quay.io/konflux-ci/git-clone-slsa:latest .
```

## Troubleshooting

### Common Issues

**SLSA verification fails with "policy not found":**
- Check that the repository has a corresponding policy in the policy repository
- Set `slsaFailOnPolicyMissing: "false"` to continue with level 1 verification

**Source-tool command not found:**
- Ensure the container image was built correctly with source-tool binary
- Verify the Containerfile includes the source-tool build step

**Authentication errors:**
- Ensure appropriate workspace credentials are provided for private repositories
- Check that SSH keys or basic auth credentials are correctly configured

### Debug Mode

Enable verbose logging:
```yaml
params:
  - name: verbose
    value: "true"
```

## Security Considerations

- **Trust boundaries**: This task runs in tenant context and should not have access to signing keys
- **Policy integrity**: Policy repositories should be protected and version-controlled
- **Credential handling**: Use workspace-based authentication rather than embedded credentials
- **Artifact verification**: Always verify trusted artifact signatures in downstream tasks

## Related Documentation

- [SLSA Source Track Requirements](https://slsa.dev/spec/draft/source-requirements)
- [slsa-framework/source-tool](https://github.com/slsa-framework/source-tool)
