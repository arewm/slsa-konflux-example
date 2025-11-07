# Trivy SBOM Vulnerability Scanning Task Design

**Date:** 2025-11-06
**Status:** Approved
**Location:** `managed-context/tasks/trivy-sbom-scan/0.1/`

## Purpose

Create a Trivy-based vulnerability scanning task as an ARM-compatible alternative to clair-scan. The task analyzes container images for known vulnerabilities and provides results for both immediate pipeline feedback and later policy evaluation by Conforma.

## Background

The clair-scan task (build-definitions/task/clair-scan/0.3/) cannot build on ARM architectures. We need an alternative scanner that:
- Works on ARM/macOS development environments
- Provides vulnerability data compatible with existing Conforma policies
- Follows the same patterns as clair-scan for drop-in replacement
- Attaches detailed reports to images for policy enforcement

## Architecture

### Task Location
`managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml`

Not in tenant-context because this is not a trusted task. In managed-context because it's part of the security scanning workflow controlled by the platform.

### Five-Step Design

**Step 1: get-image-manifests**
- Image: `quay.io/konflux-ci/konflux-test:v1.4.39@sha256:...`
- Reuses pattern from clair-scan
- Handles multi-arch images by extracting manifest digests per architecture
- Outputs: `/tekton/home/image-manifest-{arch}.sha` files

**Step 2: scan-with-trivy**
- Image: `ghcr.io/aquasecurity/trivy:0.67.2@sha256:...` (pinned)
- Scans each architecture's image using trivy
- Outputs: `/tekton/home/trivy-report-{arch}.json` (full detailed reports)

**Step 3: convert-to-clair-format**
- Image: `quay.io/konflux-ci/konflux-test:v1.4.39@sha256:...`
- Converts trivy reports to clair-compatible format using jq
- Outputs: `/tekton/home/clair-report-{arch}.json`

**Step 4: oci-attach-report**
- Image: `quay.io/konflux-ci/oras:latest@sha256:...`
- Attaches trivy reports to images via OCI
- MIME type: `application/vnd.trivy.report+json`
- Outputs: `reports.json` mapping digests to report digests

**Step 5: aggregate-results**
- Image: `quay.io/konflux-ci/konflux-test:v1.4.39@sha256:...`
- Parses trivy JSON reports
- Aggregates vulnerability counts by severity
- Separates patched vs unpatched vulnerabilities
- Outputs: Tekton results per ADR/0030

## Trivy Output Format

Trivy produces JSON with this structure:
```json
{
  "Results": [{
    "Vulnerabilities": [{
      "VulnerabilityID": "CVE-2025-1234",
      "Severity": "CRITICAL|HIGH|MEDIUM|LOW|UNKNOWN",
      "Status": "fixed|affected",
      "FixedVersion": "1.2.3"
    }]
  }]
}
```

We aggregate by:
- **vulnerabilities**: Total count per severity level
- **unpatched_vulnerabilities**: Count where Status="affected" or FixedVersion=null

## Tekton Results (ADR/0030)

**TEST_OUTPUT**
```json
{
  "result": "SUCCESS|ERROR",
  "timestamp": "2025-11-06T12:00:00Z",
  "note": "Task trivy-sbom-scan completed: Refer to SCAN_OUTPUT for vulnerabilities"
}
```

**SCAN_OUTPUT**
```json
{
  "vulnerabilities": {
    "critical": 0,
    "high": 5,
    "medium": 12,
    "low": 8,
    "unknown": 0
  },
  "unpatched_vulnerabilities": {
    "critical": 0,
    "high": 2,
    "medium": 3,
    "low": 1,
    "unknown": 0
  }
}
```

**IMAGES_PROCESSED**
```json
{
  "image": {
    "pullspec": "quay.io/org/image:tag",
    "digests": ["sha256:abc...", "sha256:def..."]
  }
}
```

**REPORTS**
```json
{
  "sha256:abc...": "sha256:report123...",
  "sha256:def...": "sha256:report456..."
}
```

## Policy Configuration Changes

### rule_data.yml
Add to `allowed_step_image_registry_prefixes`:
```yaml
- ghcr.io/aquasecurity/trivy@sha256:
```

Scope narrowly to trivy image only, not entire ghcr.io/aquasecurity registry.

### required_tasks.yml
Change vulnerability scanning requirement from:
```yaml
- clair-scan
```

To:
```yaml
- [clair-scan, trivy-sbom-scan]
```

This allows pipelines to use either scanner.

## Two-Phase Processing

**Immediate (Pipeline Execution):**
- Task runs during pipeline
- Generates aggregate vulnerability counts
- Pipeline sees results in real-time
- Can fail fast on critical vulnerabilities

**Deferred (Policy Evaluation):**
- Conforma downloads attached reports from OCI
- Evaluates detailed CVE data against policies
- Checks specific CVE allowlists, grace periods
- Makes release gate decisions

## Comparison to Clair Task

| Aspect | Clair | Trivy |
|--------|-------|-------|
| **Scanner image** | quay.io/konflux-ci/clair-in-ci:v1 | ghcr.io/aquasecurity/trivy:0.67.2 |
| **Report format** | clair + quay formats | trivy JSON |
| **MIME type** | application/vnd.redhat.clair-report+json | application/vnd.trivy.report+json |
| **ARM support** | No | Yes |
| **Conftest** | Uses rego policies | Direct JSON parsing |
| **Results** | ADR/0030 compliant | ADR/0030 compliant |

## Implementation Notes

1. Pin trivy image to specific digest for reproducibility
2. Reuse konflux-test image helpers (jq, yq, bash utilities)
3. Handle multi-arch images same as clair (iterate over manifests)
4. Use same error handling patterns as clair task
5. Follow Tekton best practices from build-definitions/.cursor/rules/tekton.mdc
6. Set `set -euo pipefail` in all bash scripts
7. Use environment variables for parameters, not direct $(params.*)

## Success Criteria

- Task runs on ARM/macOS environments
- Generates ADR/0030 compliant results
- Attaches detailed reports to images
- Conforma can evaluate attached reports with policies
- Drop-in replacement for clair-scan in pipelines
- Handles multi-arch images correctly

## Future Enhancements

- Optional SBOM download mode (scan existing SBOM vs scanning image)
- Configurable severity thresholds
- Integration with vulnerability databases beyond trivy defaults
- Custom report formats for specialized policy needs
