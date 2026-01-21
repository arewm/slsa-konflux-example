# verify-conforma-vsa Task

Custom Tekton task for policy validation with Verification Summary Attestation (VSA) generation.

## Overview

This task validates container images against Enterprise Contract policies using Conforma and optionally generates cryptographically signed VSAs containing validation metadata. VSAs provide tamper-evident records of what policies were used and what validation results were achieved.

## Features

- **Policy Validation**: Full Enterprise Contract policy evaluation
- **VSA Generation**: Optional generation of signed Verification Summary Attestations
- **Flexible Signing**: Support for cosign key-based signing and keyless signing
- **Storage Options**: Local filesystem or Rekor transparency log storage
- **Trust Boundaries**: Designed for use in managed (privileged) namespace with signing key access

## Usage

### Basic Policy Validation (No VSA)

```yaml
taskRef:
  name: verify-conforma-vsa
params:
  - name: SNAPSHOT_FILENAME
    value: "snapshot.json"
  - name: SOURCE_DATA_ARTIFACT
    value: "oci://registry/trusted-artifacts:tag"
  - name: POLICY_CONFIGURATION
    value: "namespace/ec-policy"
  - name: PUBLIC_KEY
    value: "k8s://tekton-pipelines/public-key"
  - name: ENABLE_VSA
    value: "false"  # No VSA generation
```

### Policy Validation with VSA Generation

```yaml
taskRef:
  name: verify-conforma-vsa
params:
  - name: SNAPSHOT_FILENAME
    value: "snapshot.json"
  - name: SOURCE_DATA_ARTIFACT
    value: "oci://registry/trusted-artifacts:tag"
  - name: POLICY_CONFIGURATION
    value: "namespace/ec-policy"
  - name: PUBLIC_KEY
    value: "k8s://tekton-pipelines/public-key"
  - name: ENABLE_VSA
    value: "true"  # Enable VSA generation
  - name: VSA_SIGNING_KEY
    value: "k8s://managed-namespace/vsa-signing-key"  # Private key for signing
  - name: VSA_UPLOAD
    value: "local@/var/workdir/vsa"  # Where to store VSA
```

## Parameters

### Core Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `SNAPSHOT_FILENAME` | Filename of the Snapshot within trusted artifact | Required |
| `SOURCE_DATA_ARTIFACT` | Trusted Artifact containing the Snapshot | Required |
| `POLICY_CONFIGURATION` | Policy configuration to use (`namespace/name` or git URL) | `enterprise-contract-service/default` |
| `PUBLIC_KEY` | Public key for verifying build attestations | `""` |

### VSA Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `ENABLE_VSA` | Enable VSA generation (`"true"` or `"false"`) | `"false"` |
| `VSA_SIGNING_KEY` | Private key for signing VSAs (k8s secret reference) | `""` |
| `VSA_UPLOAD` | VSA storage destination (`local@/path` or `rekor@https://url`) | `"local@/var/workdir/vsa"` |

### Additional Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `STRICT` | Fail task if policy fails | `"true"` |
| `WORKERS` | Number of parallel workers | `"4"` |
| `EFFECTIVE_TIME` | Policy evaluation time | `"now"` |
| `IGNORE_REKOR` | Skip Rekor transparency log checks | `"false"` |

See the task definition for complete parameter list.

## Results

| Result | Description |
|--------|-------------|
| `TEST_OUTPUT` | Summary of policy evaluation |
| `VSA_GENERATED` | Whether VSA was generated (`"true"` or `"false"`) |
| `VSA_LOCATION` | Storage location of generated VSA |

## VSA Signing Key Setup

### Option 1: Cosign Key-Pair

Generate a cosign key-pair and store in Kubernetes secret:

```bash
# Generate key-pair
cosign generate-key-pair

# Create secret in managed namespace
kubectl create secret generic vsa-signing-key \
  --from-file=cosign.key=cosign.key \
  --from-file=cosign.pub=cosign.pub \
  -n managed-namespace
```

Use in task:
```yaml
- name: VSA_SIGNING_KEY
  value: "k8s://managed-namespace/vsa-signing-key"
```

### Option 2: Keyless Signing (Future)

Keyless signing using Kubernetes as identity provider is planned but not yet implemented.

## VSA Storage

### Local Filesystem

Store VSA in local directory (useful for passing to subsequent tasks):

```yaml
- name: VSA_UPLOAD
  value: "local@/var/workdir/vsa"
```

VSA will be written to `/var/workdir/vsa/` directory.

### Rekor Transparency Log

Store VSA in public transparency log:

```yaml
- name: VSA_UPLOAD
  value: "rekor@https://rekor.sigstore.dev"
```

## Integration with Release Pipeline

This task is designed to replace the standard `verify-conforma-konflux-ta` task in release pipelines:

```yaml
- name: verify-conforma
  taskRef:
    resolver: "git"
    params:
      - name: url
        value: https://github.com/yourorg/slsa-konflux-example
      - name: revision
        value: main
      - name: pathInRepo
        value: managed-context/tasks/verify-conforma/0.1/verify-conforma-vsa.yaml
  params:
    - name: ENABLE_VSA
      value: "true"
    - name: VSA_SIGNING_KEY
      value: "k8s://managed-namespace/vsa-signing-key"
```

## Security Considerations

- **Signing keys must ONLY exist in managed (privileged) namespace** - never in tenant namespace
- **VSA signing keys should be different from build attestation signing keys**
- **Use appropriate RBAC** to restrict access to signing key secrets
- **Consider key rotation policies** for long-lived deployments
- **Audit all VSA generation** through pipeline logs and transparency logs

## Comparison with Standard Task

| Feature | Standard verify-conforma | This Task (verify-conforma-vsa) |
|---------|-------------------------|----------------------------------|
| Policy validation | ✅ Yes | ✅ Yes |
| VSA generation | ❌ No | ✅ Yes (optional) |
| VSA signing | ❌ No | ✅ Yes (cosign) |
| VSA storage | ❌ No | ✅ Yes (local/Rekor) |
| Results | TEST_OUTPUT | TEST_OUTPUT, VSA_GENERATED, VSA_LOCATION |

## Troubleshooting

### VSA Not Generated

Check:
1. `ENABLE_VSA` is set to `"true"`
2. `VSA_SIGNING_KEY` parameter is provided
3. Signing key secret exists and contains `cosign.key`
4. Task has permission to read the secret

### Signature Verification Fails

Check:
1. Signing key format is correct (PEM-encoded)
2. COSIGN_PASSWORD environment variable if key is encrypted
3. Secret is in the correct namespace
4. Secret contains `cosign.key` (not `cosign.priv` or other names)

### Storage Location Not Found

Check:
1. Path in `VSA_UPLOAD` is writable
2. Volume mounts are configured correctly
3. For Rekor: network access to Rekor server is allowed

## References

- [Enterprise Contract CLI](https://github.com/enterprise-contract/ec-cli)
- [Conforma Documentation](https://conforma.dev)
- [SLSA VSA Specification](https://slsa.dev/spec/v1.0/verification_summary)
- [Cosign Documentation](https://docs.sigstore.dev/cosign/overview/)
