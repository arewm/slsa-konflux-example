# Conforma VSA Task (Managed Context)

This task operates in the **managed namespace** to perform trusted policy evaluation and VSA (Verification Summary Attestation) payload generation. It provides authoritative policy decisions in a controlled environment with access to managed signing keys.

## 🎯 Purpose

- **Trusted Policy Evaluation**: Authoritative policy enforcement in managed environment
- **VSA Payload Generation**: Creates verification summary payloads for signing
- **Evidence Collection**: Gathers policy evaluation evidence for attestation
- **Security Authority**: Final policy decisions with managed cryptographic keys

## 🔧 Features

### Trusted Policy Evaluation
- Enterprise Contract policy validation in controlled environment
- Authoritative security policy enforcement
- Vulnerability scanning integration with trusted keys
- Compliance checking with managed authority

### VSA Payload Generation
- SLSA-compliant verification summary creation
- Policy evaluation evidence collection with cryptographic binding
- Trust artifact generation for downstream signing
- Structured attestation payload preparation with managed context

### Enhanced Security
- Managed signing key access for policy evaluation
- Isolated evaluation environment with elevated privileges
- Complete audit trail for all policy decisions
- Cryptographic binding of evaluation results

## 📋 Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `image` | string | Yes | Container image to evaluate |
| `buildArtifacts` | string | Yes | Path to build artifacts from tenant context |
| `policy` | string | Yes | Policy bundle reference or path |
| `managedKey` | string | Yes | Managed signing key for evaluation authority |
| `vsaPayloadPath` | string | Yes | Path for VSA payload output |
| `evidencePath` | string | No | Path for evaluation evidence output |

## 🔄 Workspaces

| Workspace | Description | Required |
|-----------|-------------|----------|
| `build-artifacts` | Build artifacts from tenant context | Yes |
| `trust-artifacts` | Trust artifact output directory | Yes |
| `policy-config` | Managed policy configuration | Yes |
| `signing-config` | Managed signing key configuration | Yes |

## 📤 Results

| Result | Description |
|--------|-------------|
| `evaluation-result` | Authoritative policy evaluation outcome |
| `vsa-payload-path` | Path to generated VSA payload |
| `evidence-path` | Path to evaluation evidence |
| `authority-signature` | Managed context evaluation signature |

## 🛡️ Managed Context Features

### Trusted Policy Evaluation
```yaml
steps:
  - name: managed-policy-evaluation
    image: ghcr.io/konflux-ci/conforma-vsa-managed:latest
    script: |
      #!/bin/bash
      # Validate build artifacts from tenant context
      validate-trust-artifacts $(workspaces.build-artifacts.path)
      
      # Perform authoritative policy evaluation
      conftest verify \
        --policy $(params.policy) \
        --authority-key $(workspaces.signing-config.path)/$(params.managedKey) \
        $(params.image)
      
      # Generate VSA payload with managed authority
      vsa-generator create \
        --input=/workspace/results/evaluation.json \
        --output=$(params.vsaPayloadPath) \
        --subject=$(params.image) \
        --authority="managed.konflux.example.com" \
        --signing-key=$(params.managedKey)
```

### Trust Artifact Validation
```yaml
steps:
  - name: validate-tenant-artifacts
    image: ghcr.io/konflux-ci/conforma-vsa-managed:latest
    script: |
      #!/bin/bash
      # Cryptographically verify tenant context outputs
      verify-trust-artifacts \
        --artifacts=$(workspaces.build-artifacts.path) \
        --expected-tenant="tenant.konflux.example.com" \
        --validation-key=$(workspaces.signing-config.path)/tenant-validation.pub
```

## 🔗 Integration

### Upstream Dependencies
- **Build Artifacts**: Validated outputs from tenant context
- **Managed Policies**: Enterprise contract policies in managed environment
- **Signing Keys**: Managed cryptographic keys for authority

### Downstream Consumption
- **VSA Sign Task**: Consumes VSA payload for final cryptographic signing
- **Release Verification**: Uses evaluation evidence for release authorization

## 📁 Output Format

### VSA Payload Structure (Managed Authority)
```json
{
  "vsaPayload": {
    "_type": "https://in-toto.io/Statement/v0.1",
    "predicateType": "https://slsa.dev/verification_summary/v1",
    "subject": [
      {
        "name": "registry.example.com/app:v1.0.0",
        "digest": {
          "sha256": "abc123..."
        }
      }
    ],
    "predicate": {
      "verifier": {
        "id": "https://managed.konflux.example.com/conforma-vsa",
        "version": "v1.2.3"
      },
      "timeVerified": "2024-01-01T12:00:00Z",
      "resourceUri": "registry.example.com/app:v1.0.0",
      "policy": {
        "uri": "oci://managed.konflux.example.com/policies/enterprise-contract:v1.0",
        "digest": {
          "sha256": "def456..."
        }
      },
      "inputAttestations": [
        {
          "uri": "tenant-build-artifacts",
          "digest": {
            "sha256": "ghi789..."
          }
        }
      ],
      "verificationResult": "PASSED",
      "verifiedLevels": ["SLSA_BUILD_LEVEL_3"],
      "dependencyLevels": {
        "registry.example.com/base:latest": "SLSA_BUILD_LEVEL_2"
      },
      "managedAuthority": {
        "keyId": "managed-policy-key-2024",
        "signature": "MEUCIQD7+..."
      }
    }
  }
}
```

## 🚨 Security Considerations

### Managed Context Authority
- **Exclusive Policy Authority**: Only managed context makes final policy decisions
- **Cryptographic Binding**: All evaluations signed with managed keys
- **Trust Verification**: Validates all tenant context inputs before evaluation
- **Audit Trail**: Complete immutable record of all policy decisions

### Trust Boundaries
- **Input Validation**: Cryptographically verifies all tenant artifacts
- **Key Isolation**: Managed signing keys never accessible to tenant context
- **Authority Establishment**: Clear chain of custody from evaluation to signing
- **Evidence Preservation**: Complete evaluation evidence for compliance

## 📊 Monitoring and Metrics

### Key Metrics
- Policy evaluation success/failure rates in managed context
- Trust artifact validation results
- VSA payload generation completeness
- Managed authority operation audit trail

### Security Alerts
- Failed trust artifact validation from tenant context
- Policy evaluation anomalies or bypasses
- Unauthorized managed key access attempts
- VSA payload generation failures

## 🔄 Workflow Integration

### Managed Pipeline Context
```yaml
# Example managed pipeline step
- name: trusted-policy-evaluation
  taskRef:
    name: conforma-vsa
  params:
    - name: image
      value: "$(tasks.receive-artifacts.results.image-url)"
    - name: buildArtifacts
      value: "$(workspaces.build-artifacts.path)/tenant-outputs"
    - name: policy
      value: "oci://managed.konflux.example.com/policies/enterprise-contract:v1.0"
    - name: managedKey
      value: "policy-authority-key-2024"
  workspaces:
    - name: build-artifacts
      workspace: build-artifacts-ws
    - name: trust-artifacts
      workspace: trust-artifacts-ws
    - name: signing-config
      workspace: managed-signing-ws
```

## 📖 Related Documentation

- [Enterprise Contract Documentation](https://enterprisecontract.dev/)
- [SLSA VSA Specification](https://slsa.dev/verification-summary)
- [Trust Model](../../docs/trust-model.md)
- [Managed Context Security](../../docs/managed-context-security.md)
- [Key Management](../../docs/key-management.md)