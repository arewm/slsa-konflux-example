# Conforma → VSA JSON Converter Test Strategy

## Overview

This test strategy covers the comprehensive testing of the Conforma policy evaluation output to SLSA VSA v1.0 JSON converter for WS5 (VSA Generation). The converter transforms Conforma SLSA3 policy evaluation results into standard SLSA Verification Summary Attestation format.

## Test Requirements Analysis

### Input Format: Conforma Policy Evaluation Output
Based on analysis of existing Conforma CLI output examples:
```json
{
  "success": true/false,
  "components": [
    {
      "name": "component-name",
      "containerImage": "registry.example.com/image@sha256:abc123...",
      "source": {},
      "success": true/false,
      "signatures": [...],
      "attestations": [...]
    }
  ],
  "key": "...",
  "policy": {
    "sources": [...],
    "rekorUrl": "...",
    "publicKey": "..."
  },
  "ec-version": "v0.1.0",
  "effective-time": "2024-01-01T12:00:00Z"
}
```

### Output Format: SLSA VSA v1.0
Target format based on SLSA specification and implementation examples:
```json
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://slsa.dev/verification_summary/v1",
  "subject": [
    {
      "name": "registry.example.com/image",
      "digest": {
        "sha256": "abc123..."
      }
    }
  ],
  "predicate": {
    "verifier": {
      "id": "https://managed.konflux.example.com/conforma-vsa",
      "version": "v1.0.0"
    },
    "timeVerified": "2024-01-01T12:00:00Z",
    "resourceUri": "registry.example.com/image",
    "policy": {
      "uri": "oci://managed.konflux.example.com/policies/enterprise-contract:v1.0",
      "digest": {
        "sha256": "def456..."
      }
    },
    "inputAttestations": [...],
    "verificationResult": "PASSED|FAILED",
    "verifiedLevels": ["SLSA_BUILD_LEVEL_3"],
    "dependencyLevels": {}
  }
}
```

## Test Case Categories

### 1. Happy Path Tests

#### Test Case 1.1: PASSED Policy Evaluation → Valid VSA
**Input:** Conforma JSON with `"success": true` and successful component evaluation
**Expected Output:** VSA with `"verificationResult": "PASSED"`
**Validation:** 
- All required VSA fields present
- Timestamps correctly converted
- Subject properly extracted from containerImage
- Policy information mapped correctly

#### Test Case 1.2: Multiple Components Success
**Input:** Conforma JSON with multiple components, all successful
**Expected Output:** VSA covering all components as subjects
**Validation:**
- Multiple subjects in VSA
- Each component properly represented

### 2. Failure Scenarios

#### Test Case 2.1: FAILED Policy Evaluation → Failed VSA
**Input:** Conforma JSON with `"success": false`
**Expected Output:** VSA with `"verificationResult": "FAILED"`
**Validation:**
- Failure reason preserved in VSA
- Partial success components handled correctly

#### Test Case 2.2: Mixed Component Results
**Input:** Some components pass, others fail
**Expected Output:** VSA with overall result and component-specific details
**Validation:**
- Overall result determined by policy (fail-fast vs. continue)
- Individual component results preserved

### 3. Edge Cases

#### Test Case 3.1: Missing Optional Fields
**Input:** Conforma JSON missing non-critical fields (e.g., signatures, attestations)
**Expected Output:** Valid VSA with available information
**Validation:**
- Converter handles missing optional fields gracefully
- Required VSA fields still populated

#### Test Case 3.2: Empty Components Array
**Input:** Conforma JSON with empty components array
**Expected Output:** VSA with no subjects or appropriate error
**Validation:**
- Graceful handling of edge case
- Clear error message if invalid

#### Test Case 3.3: Malformed Container Image References
**Input:** Invalid or missing digest in containerImage field
**Expected Output:** Error or sanitized output
**Validation:**
- Input validation catches malformed references
- Error messages are descriptive

### 4. Error Conditions

#### Test Case 4.1: Malformed JSON Input
**Input:** Invalid JSON syntax
**Expected Output:** Parse error with clear message
**Validation:**
- Error handling for JSON parsing failures
- Informative error messages

#### Test Case 4.2: Missing Required Fields
**Input:** Conforma JSON missing critical fields (effective-time, components)
**Expected Output:** Validation error
**Validation:**
- Input validation identifies missing required fields
- Specific field requirements documented

#### Test Case 4.3: Invalid Timestamp Formats
**Input:** Malformed or missing effective-time
**Expected Output:** Error or default timestamp handling
**Validation:**
- Timestamp parsing handles various formats
- RFC3339 compliance for output

### 5. Schema Validation Tests

#### Test Case 5.1: VSA Schema Compliance
**Input:** Any valid Conforma input
**Expected Output:** VSA that validates against SLSA v1.0 schema
**Validation:**
- JSON schema validation for VSA output
- SLSA specification compliance

#### Test Case 5.2: Predicate Type Validation
**Input:** Various inputs
**Expected Output:** Correct predicate type `https://slsa.dev/verification_summary/v1`
**Validation:**
- Predicate type is always correctly set
- Statement type is `https://in-toto.io/Statement/v0.1`

## Test Data Specifications

### Sample Input 1: Successful Single Component
```json
{
  "success": true,
  "components": [
    {
      "name": "test-app",
      "containerImage": "quay.io/test/app@sha256:a1b2c3d4e5f6789012345678901234567890abcdef1234567890abcdef123456",
      "source": {
        "git": {
          "url": "https://github.com/example/test-app",
          "revision": "abc123def456"
        }
      },
      "success": true,
      "signatures": [
        {
          "keyid": "test-key-1",
          "sig": "MEUCIQDtest..."
        }
      ],
      "attestations": [
        {
          "type": "https://in-toto.io/Statement/v0.1",
          "predicateType": "https://slsa.dev/provenance/v0.2"
        }
      ]
    }
  ],
  "key": "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...",
  "policy": {
    "sources": [
      {
        "policy": [
          "oci://registry.example.com/policies/enterprise-contract:v1.0"
        ]
      }
    ],
    "rekorUrl": "https://rekor.sigstore.dev",
    "publicKey": "-----BEGIN PUBLIC KEY-----\n..."
  },
  "ec-version": "v0.3.0",
  "effective-time": "2024-01-15T14:30:00Z"
}
```

### Expected Output 1: Corresponding VSA
```json
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://slsa.dev/verification_summary/v1",
  "subject": [
    {
      "name": "quay.io/test/app",
      "digest": {
        "sha256": "a1b2c3d4e5f6789012345678901234567890abcdef1234567890abcdef123456"
      }
    }
  ],
  "predicate": {
    "verifier": {
      "id": "https://managed.konflux.example.com/conforma-vsa",
      "version": "v0.3.0"
    },
    "timeVerified": "2024-01-15T14:30:00Z",
    "resourceUri": "quay.io/test/app@sha256:a1b2c3d4e5f6789012345678901234567890abcdef1234567890abcdef123456",
    "policy": {
      "uri": "oci://registry.example.com/policies/enterprise-contract:v1.0"
    },
    "inputAttestations": [
      {
        "uri": "test-app-attestations",
        "digest": {
          "sha256": "computed-from-attestations"
        }
      }
    ],
    "verificationResult": "PASSED",
    "verifiedLevels": ["SLSA_BUILD_LEVEL_3"]
  }
}
```

### Sample Input 2: Failed Evaluation
```json
{
  "success": false,
  "components": [
    {
      "name": "failing-app",
      "containerImage": "quay.io/test/failing-app@sha256:deadbeef12345678901234567890123456789012345678901234567890123456",
      "success": false,
      "violations": [
        {
          "rule": "required_checks.required_tasks",
          "message": "Required task 'security-scan' not found"
        }
      ]
    }
  ],
  "policy": {
    "sources": [
      {
        "policy": ["git::https://github.com/enterprise/policies.git"]
      }
    ]
  },
  "ec-version": "v0.3.0",
  "effective-time": "2024-01-15T14:35:00Z"
}
```

### Expected Output 2: Failed VSA
```json
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://slsa.dev/verification_summary/v1",
  "subject": [
    {
      "name": "quay.io/test/failing-app",
      "digest": {
        "sha256": "deadbeef12345678901234567890123456789012345678901234567890123456"
      }
    }
  ],
  "predicate": {
    "verifier": {
      "id": "https://managed.konflux.example.com/conforma-vsa",
      "version": "v0.3.0"
    },
    "timeVerified": "2024-01-15T14:35:00Z",
    "resourceUri": "quay.io/test/failing-app@sha256:deadbeef12345678901234567890123456789012345678901234567890123456",
    "policy": {
      "uri": "git::https://github.com/enterprise/policies.git"
    },
    "inputAttestations": [],
    "verificationResult": "FAILED",
    "verifiedLevels": []
  }
}
```

## Validation Framework

### 1. Schema Validation
- **Tool:** JSON Schema validation using SLSA VSA v1.0 specification
- **Implementation:** Use `ajv` (JavaScript) or `jsonschema` (Python) libraries
- **Validation Points:**
  - VSA structure compliance
  - Required field presence
  - Field type validation
  - Format validation (URIs, timestamps)

### 2. Field Mapping Validation
- **Purpose:** Ensure correct transformation from Conforma to VSA fields
- **Implementation:** Custom validation functions
- **Checks:**
  - Subject extraction from containerImage
  - Timestamp format conversion
  - Verification result mapping
  - Policy URI transformation

### 3. End-to-End Validation
- **Purpose:** Validate complete conversion pipeline
- **Implementation:** Integration tests with real Conforma output
- **Validation:**
  - Round-trip conversion integrity
  - VSA can be verified by SLSA tooling
  - Generated VSA accepts cryptographic signing

### 4. SLSA Specification Compliance
- **Tool:** SLSA verification tools from slsa-framework/slsa-verifier
- **Implementation:** Use SLSA verification libraries
- **Validation:**
  - VSA format follows SLSA v1.0 specification exactly
  - Predicate structure matches SLSA VSA schema
  - Statement envelope is properly formed

## Performance Requirements

### 1. Conversion Time
- **Requirement:** Convert typical Conforma output (1-10 components) in <100ms
- **Large Input:** Handle 100+ components in <1 second
- **Measurement:** Use Go benchmarks or Python `timeit` module

### 2. Memory Usage
- **Requirement:** Memory usage should not exceed 2x input size
- **Large Input:** Process 10MB Conforma file with <50MB peak memory
- **Measurement:** Memory profiling tools (Go pprof, Python memory-profiler)

### 3. Concurrent Processing
- **Requirement:** Support concurrent conversion of multiple files
- **Target:** Handle 10 concurrent conversions without degradation
- **Measurement:** Load testing with concurrent requests

### 4. Error Handling Performance
- **Requirement:** Invalid input detection within 10ms
- **Target:** Parse errors identified before full processing
- **Measurement:** Benchmark error handling paths

## Test Implementation Framework

### 1. Unit Tests
```bash
# Go implementation
go test ./converter -v -race -cover

# Python implementation  
pytest tests/unit/ -v --cov=converter
```

### 2. Integration Tests
```bash
# Test with real Conforma outputs
./test-integration.sh --conforma-samples ./samples/
```

### 3. Performance Tests
```bash
# Benchmark conversion performance
go test -bench=. -benchmem ./converter

# Load testing
./load-test.sh --concurrent=10 --iterations=100
```

### 4. Schema Validation Tests
```bash
# Validate output against SLSA schema
./validate-schema.sh --schema slsa-vsa-v1.0.json --output samples/
```

## Test Execution Strategy

### 1. Development Phase
- Run unit tests on every code change
- Integration tests on feature completion
- Performance regression tests weekly

### 2. Pre-release Validation
- Full test suite execution
- Performance benchmark comparison
- Schema compliance validation
- Real-world sample testing

### 3. Continuous Integration
- Automated test execution on PR
- Performance regression detection
- Schema validation in CI pipeline
- Multi-platform testing (Linux, macOS)

### 4. Post-deployment Monitoring
- Conversion success rate monitoring
- Performance metrics collection
- Error pattern analysis
- Schema compliance tracking

## Success Criteria

### 1. Functional Success
- ✅ 100% pass rate on happy path tests
- ✅ Proper error handling for all failure scenarios
- ✅ Edge cases handled gracefully
- ✅ All outputs validate against SLSA VSA v1.0 schema

### 2. Performance Success
- ✅ <100ms conversion time for typical inputs
- ✅ <1s conversion time for large inputs (100+ components)
- ✅ Memory usage <2x input size
- ✅ 10 concurrent conversions without degradation

### 3. Quality Success
- ✅ 95%+ code coverage
- ✅ No memory leaks detected
- ✅ Clean error messages for all failure modes
- ✅ Generated VSA can be cryptographically signed

### 4. Compliance Success
- ✅ 100% SLSA VSA v1.0 specification compliance
- ✅ Compatible with existing VSA verification tools
- ✅ Proper in-toto Statement envelope format
- ✅ Trust boundary separation maintained

## Risk Mitigation

### 1. Schema Evolution Risk
- **Risk:** SLSA VSA specification changes
- **Mitigation:** Version-aware converter with backwards compatibility

### 2. Performance Degradation Risk
- **Risk:** Large input handling becomes slow
- **Mitigation:** Streaming processing for large inputs, memory optimization

### 3. Data Loss Risk
- **Risk:** Information lost during conversion
- **Mitigation:** Comprehensive field mapping validation, audit logging

### 4. Security Risk
- **Risk:** Malicious input causing security issues
- **Mitigation:** Input sanitization, size limits, timeout protection

This test strategy ensures the Conforma → VSA converter is robust, performant, and fully compliant with SLSA specifications while maintaining the trust boundary separation required for the Konflux architecture.