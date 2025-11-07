# trivy-sbom-scan

Scans container images for vulnerabilities using Trivy vulnerability scanner.

## Purpose

ARM-compatible alternative to clair-scan task. Analyzes container images for known CVEs and produces ADR/0030 compliant results for Conforma policy evaluation.

## Parameters

| Name | Description | Default |
|------|-------------|---------|
| image-digest | Image digest to scan | (required) |
| image-url | Image URL | (required) |
| image-platform | Platform built by | "" |
| ca-trust-config-map-name | ConfigMap for CA bundle | trusted-ca |
| ca-trust-config-map-key | Key in ConfigMap for CA bundle | ca-bundle.crt |

## Results

| Name | Description |
|------|-------------|
| TEST_OUTPUT | Task execution result (SUCCESS/ERROR) |
| SCAN_OUTPUT | Vulnerability counts by severity |
| IMAGES_PROCESSED | Images and digests processed |
| REPORTS | Mapping of image digests to report digests |

## Usage

```yaml
- name: trivy-scan
  taskRef:
    name: trivy-sbom-scan
  params:
    - name: image-digest
      value: $(tasks.build.results.IMAGE_DIGEST)
    - name: image-url
      value: $(tasks.build.results.IMAGE_URL)
```

## SCAN_OUTPUT Format

```json
{
  "vulnerabilities": {
    "critical": 2,
    "high": 15,
    "medium": 47,
    "low": 23,
    "unknown": 1
  },
  "unpatched_vulnerabilities": {
    "critical": 0,
    "high": 3,
    "medium": 12,
    "low": 8,
    "unknown": 0
  }
}
```

## Architecture

1. **get-image-manifests**: Extract manifest digests for multi-arch images
2. **scan-with-trivy**: Run trivy scanner on each architecture
3. **oci-attach-report**: Attach detailed reports to image via OCI
4. **aggregate-results**: Parse and aggregate vulnerability counts

## Policy Integration

Reports are attached to images with MIME type `application/vnd.trivy.report+json` for later retrieval by Conforma during policy evaluation.
