# SLSA Source Verification Policy

This custom policy validates that the `verify-source` task runs correctly and achieves the required SLSA source level.

## Rules

### 1. `required_level_achieved`
**Collection**: `slsa_source`

Ensures the verify-source task achieved the minimum required SLSA source level.

**Failure Example**:
```
verify-source task achieved level 2, but minimum required level is 3
```

**Resolution**: Ensure your source repository meets the requirements for SLSA source level 3. This typically includes:
- Version control (git)
- Verified history (protected branches, code review)
- Retention and tamper resistance

### 2. `result_provided`
**Collection**: `slsa_source`

Ensures the verify-source task provides the `SLSA_SOURCE_LEVEL_ACHIEVED` result.

**Failure Example**:
```
verify-source task did not provide SLSA_SOURCE_LEVEL_ACHIEVED result
```

**Resolution**: Ensure you're using verify-source task version 0.1 or later.

### 3. `parameters_match_git_clone`
**Collection**: `slsa_source`

Ensures verify-source receives the same URL and revision as git-clone produced.

**Failure Example**:
```
verify-source task parameter URL="https://github.com/different/repo.git" does not match git-clone result url="https://github.com/example/repo.git"
```

**Resolution**: Configure verify-source to use git-clone task results:
```yaml
- name: verify-source
  params:
    - name: URL
      value: $(tasks.git-clone.results.url)
    - name: REVISION
      value: $(tasks.git-clone.results.commit)
```

### 4. `verified_all_materials`
**Collection**: `slsa_source`

Ensures verify-source ran for all git repositories in the attestation materials.

**Failure Example**:
```
No verify-source task found for repository git+https://github.com/example/lib.git at commit abc123
```

**Resolution**: For multi-repo builds, add a verify-source task for each cloned repository.

## Configuration

Configure the minimum required SLSA source level in `rule_data.yml`:

```yaml
rule_data:
  # Minimum SLSA source level required (1, 2, or 3)
  # Defaults to "1" if not specified
  slsa_source_min_level: "3"
```

### SLSA Source Levels

- **Level 1**: Version controlled
  - Source code tracked in version control (git)
  - Immutable references (commit SHAs)

- **Level 2**: Version controlled + verified history
  - Level 1 requirements
  - Code review required
  - Protected branches

- **Level 3**: Level 2 + retention/tamper resistance
  - Level 2 requirements
  - Repository retention policies
  - Tamper-resistant history

See [SLSA source Levels](https://slsa.dev/spec/v1.2/source-requirements) for details.

## Testing

Run tests locally:

```bash
cd managed-context/policies/ec-policy-data
opa test policy/custom/slsa_source_verification/
```

Or using the Conforma CLI:

```bash
ec test policy/custom/slsa_source_verification/
```

## Example Pipeline Integration

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: build-pipeline
spec:
  tasks:
    - name: git-clone
      taskRef:
        name: git-clone
      params:
        - name: url
          value: $(params.git-url)
        - name: revision
          value: $(params.git-revision)

    - name: verify-source
      runAfter:
        - git-clone
      taskRef:
        name: verify-source
      params:
        - name: URL
          value: $(tasks.git-clone.results.url)
        - name: REVISION
          value: $(tasks.git-clone.results.commit)

    # ... other tasks ...
```

## Enabling in EnterpriseContractPolicy

Add the custom policy and `@slsa_source` collection to your ECP:

```yaml
apiVersion: appstudio.redhat.com/v1alpha1
kind: EnterpriseContractPolicy
metadata:
  name: release-policy
spec:
  sources:
    - name: Release Policies
      policy:
        - oci::quay.io/conforma/release-policy:latest
        # Add custom policy
        - github.com/your-org/your-repo//managed-context/policies/ec-policy-data/policy
      data:
        - github.com/your-org/your-repo//managed-context/policies/ec-policy-data/data
      config:
        include:
          - '@slsa3'        # Build track policies
          - '@slsa_source'  # Source track policies
```

## Multi-Repository Builds

For builds that clone multiple repositories, ensure each has a corresponding verify-source task:

```yaml
tasks:
  # Main repository
  - name: git-clone-main
    taskRef:
      name: git-clone
    params:
      - name: url
        value: $(params.main-repo-url)

  - name: verify-source-main
    runAfter: [git-clone-main]
    taskRef:
      name: verify-source
    params:
      - name: URL
        value: $(tasks.git-clone-main.results.url)
      - name: REVISION
        value: $(tasks.git-clone-main.results.commit)

  # Library repository
  - name: git-clone-lib
    taskRef:
      name: git-clone
    params:
      - name: url
        value: $(params.lib-repo-url)

  - name: verify-source-lib
    runAfter: [git-clone-lib]
    taskRef:
      name: verify-source
    params:
      - name: URL
        value: $(tasks.git-clone-lib.results.url)
      - name: REVISION
        value: $(tasks.git-clone-lib.results.commit)
```
