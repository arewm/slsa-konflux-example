# Conforma → VSA JSON Converter

This Go program converts Conforma policy evaluation output to SLSA Verification Summary Attestation (VSA) v1.0 format.

## Overview

The converter transforms Conforma SLSA3 policy evaluation results into standard SLSA VSA format, enabling integration with VSA-aware tooling and maintaining compliance with SLSA specifications.

## Features

- **SLSA VSA v1.0 Compliance**: Outputs fully compliant SLSA VSA format
- **Comprehensive Validation**: Input validation and output schema compliance
- **Error Handling**: Robust error handling with descriptive messages
- **Flexible Input**: Supports various Conforma output formats
- **CLI Interface**: Command-line tool for easy integration into pipelines

## Installation

### Build from Source

```bash
# Clone the repository and navigate to the converter
cd managed-context/tasks/conforma-vsa/scripts

# Build the binary
make build

# Run tests
make test

# Install system-wide (optional)
make install
```

### Requirements

- Go 1.21 or later
- No external dependencies (pure Go stdlib)

## Usage

### Basic Usage

```bash
./convert-conforma-to-vsa \
  -input conforma-evaluation.json \
  -output vsa-output.json \
  -verifier-id "https://managed.konflux.example.com/conforma-vsa" \
  -verifier-version "v1.0.0"
```

### Command Line Options

| Flag | Description | Required | Default |
|------|-------------|----------|---------|
| `-input` | Path to Conforma evaluation JSON file | Yes | - |
| `-output` | Path to output VSA JSON file | Yes | - |
| `-subject` | Override subject image URL | No | Uses containerImage from input |
| `-verifier-id` | VSA verifier identifier | No | `https://managed.konflux.example.com/conforma-vsa` |
| `-verifier-version` | VSA verifier version | No | `v1.0.0` |

### Examples

#### Successful Policy Evaluation

Input (Conforma format):
```json
{
  "success": true,
  "components": [
    {
      "name": "test-app",
      "containerImage": "quay.io/test/app@sha256:abc123...",
      "success": true,
      "attestations": [...]
    }
  ],
  "policy": {
    "sources": [
      {"policy": ["oci://registry.example.com/policies/enterprise-contract@sha256:def456"]}
    ]
  },
  "ec-version": "v0.3.0",
  "effective-time": "2024-01-15T14:30:00Z"
}
```

Output (SLSA VSA format):
```json
{
  "_type": "https://in-toto.io/Statement/v1",
  "subject": [
    {
      "name": "quay.io/test/app",
      "digest": {"sha256": "abc123..."}
    }
  ],
  "predicateType": "https://slsa.dev/verification_summary/v1",
  "predicate": {
    "verifier": {
      "id": "https://managed.konflux.example.com/conforma-vsa",
      "version": "v0.3.0"
    },
    "timeVerified": "2024-01-15T14:30:00Z",
    "resourceUri": "quay.io/test/app@sha256:abc123...",
    "policy": {
      "uri": "oci://registry.example.com/policies/enterprise-contract@sha256:def456",
      "digest": {"sha256": "def456"}
    },
    "verificationResult": "PASSED",
    "verifiedLevels": ["SLSA_BUILD_LEVEL_3"]
  }
}
```

#### Failed Policy Evaluation

For failed evaluations, the converter will:
- Set `verificationResult` to `"FAILED"`
- Set `verifiedLevels` to empty array `[]`
- Preserve violation information where applicable

## Conversion Logic

### Input Mapping

| Conforma Field | VSA Field | Notes |
|----------------|-----------|-------|
| `success` | `verificationResult` | `true` → `"PASSED"`, `false` → `"FAILED"` |
| `components[].containerImage` | `subject[]` | Parsed to extract name and digest |
| `effective-time` | `timeVerified` | Converted to RFC3339 UTC format |
| `policy.sources[0].policy[0]` | `policy.uri` | First policy source used |
| `ec-version` | `verifier.version` | Falls back to verifier-version flag |
| `components[].attestations` | `inputAttestations` | Referenced as URIs |

### SLSA Level Determination

The converter determines SLSA build levels based on evaluation results:

| Condition | Verified Levels |
|-----------|----------------|
| All successful, no violations | `["SLSA_BUILD_LEVEL_3"]` |
| Successful with warnings | `["SLSA_BUILD_LEVEL_2"]` |
| Failed or has violations | `[]` (empty) |

## Integration

### Tekton Pipeline Usage

```yaml
- name: convert-conforma-to-vsa
  image: golang:1.21
  script: |
    #!/bin/bash
    cd /workspace/converter
    ./convert-conforma-to-vsa \
      --input=/workspace/conforma-results/evaluation.json \
      --output=/workspace/vsa/vsa-payload.json \
      --subject=$(params.image-url) \
      --verifier-id=$(params.verifier-id)
```

### Container Image

Build as container:
```dockerfile
FROM golang:1.21-alpine AS builder
COPY . /src
WORKDIR /src
RUN go build -o convert-conforma-to-vsa .

FROM alpine:latest
RUN apk --no-cache add ca-certificates
COPY --from=builder /src/convert-conforma-to-vsa /usr/local/bin/
ENTRYPOINT ["convert-conforma-to-vsa"]
```

## Validation

### Input Validation

The converter validates:
- JSON syntax and structure
- Required fields presence (`effective-time`, `components`)
- Container image format (must include `@sha256:` digest)
- Component names and success status

### Output Validation

The converter ensures:
- SLSA VSA v1.0 specification compliance
- Required VSA fields presence
- Proper in-toto Statement envelope format
- Valid URI and timestamp formats

## Testing

### Unit Tests

```bash
# Run all tests
make test

# Run with coverage
make test-coverage

# Run specific test
go test -run TestParseTime -v
```

### Integration Tests

```bash
# Run example conversions
make run-example

# Test with custom files
./build/convert-conforma-to-vsa \
  -input your-conforma-file.json \
  -output test-output.json
```

### Performance Testing

```bash
# Run benchmarks
make benchmark

# Load testing
./load-test.sh --concurrent=10 --iterations=100
```

## Error Handling

The converter provides detailed error messages for common issues:

- **Invalid JSON**: Parse errors with line/column information
- **Missing fields**: Specific field requirements
- **Format errors**: Image reference and timestamp format issues
- **Validation failures**: Schema compliance errors

Example error output:
```
Conversion failed: invalid Conforma input: component[0]: containerImage must include sha256 digest
```

## Compliance

### SLSA VSA v1.0

The converter generates VSAs that comply with:
- [SLSA VSA v1.0 Specification](https://slsa.dev/verification_summary/v1)
- [in-toto Statement v1.0](https://in-toto.io/Statement/v1)

### Standards Adherence

- **RFC3339**: All timestamps in UTC
- **OCI References**: Container image references with digests
- **URI Format**: Policy and attestation references as valid URIs

## Development

### Project Structure

```
scripts/
├── convert-conforma-to-vsa.go      # Main converter implementation
├── convert-conforma-to-vsa_test.go # Comprehensive test suite
├── go.mod                          # Go module definition
├── Makefile                        # Build and test automation
├── README.md                       # This documentation
└── testdata/                       # Sample input files
    ├── conforma-success.json       # Successful evaluation example
    └── conforma-failure.json       # Failed evaluation example
```

### Contributing

1. Add tests for new functionality
2. Run `make test` and `make lint` before submitting
3. Update documentation for interface changes
4. Follow Go best practices and conventions

### Dependencies

The converter uses only Go standard library:
- `encoding/json`: JSON parsing and generation
- `flag`: Command-line argument parsing  
- `time`: Timestamp handling and RFC3339 formatting
- `strings`: String manipulation for image references

No external dependencies required for core functionality.

## License

This converter is part of the SLSA Konflux Example project and follows the same licensing terms.