# Trivy SBOM Scan Task Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create ARM-compatible trivy-sbom-scan task as drop-in replacement for clair-scan

**Architecture:** Four-step Tekton task that handles multi-arch images, scans with trivy, attaches reports to OCI, and produces ADR/0030 compliant results for Conforma policy evaluation.

**Tech Stack:** Tekton v1, Trivy (multi-arch digest), ORAS, konflux-test utilities (jq/yq/bash)

---

## Task 1: Update Policy to Allow Trivy Image

**Files:**
- Modify: `managed-context/policies/ec-policy-data/data/rule_data.yml:21-24`

**Step 1: Read current rule_data.yml**

Run: `cat managed-context/policies/ec-policy-data/data/rule_data.yml | grep -A5 allowed_step_image_registry_prefixes`

Expected output showing current allowed prefixes

**Step 2: Add trivy image to allowed list**

Add this line after line 24 (`registry.redhat.io/`):
```yaml
  - ghcr.io/aquasecurity/trivy@sha256:e2b22eac59c02003d8749f5b8d9bd073b62e30fefaef5b7c8371204e0a4b0c08
```

Complete section should be:
```yaml
  allowed_step_image_registry_prefixes:
  - quay.io/konflux-ci/
  - registry.access.redhat.com/
  - registry.redhat.io/
  - ghcr.io/aquasecurity/trivy@sha256:e2b22eac59c02003d8749f5b8d9bd073b62e30fefaef5b7c8371204e0a4b0c08
```

**Step 3: Verify YAML syntax**

Run: `yq eval '.' managed-context/policies/ec-policy-data/data/rule_data.yml > /dev/null && echo "YAML valid"`

Expected: `YAML valid`

**Step 4: Commit policy update**

```bash
git add managed-context/policies/ec-policy-data/data/rule_data.yml
git commit -s -m "feat: allow trivy scanner image in policy

Add ghcr.io/aquasecurity/trivy@sha256:e2b22eac... (multi-arch) to
allowed step images for vulnerability scanning with trivy-sbom-scan task.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
Assisted-by: Cursor AI"
```

Expected: Clean commit with sign-off

---

## Task 2: Create Trivy Task Directory Structure

**Files:**
- Create: `managed-context/tasks/trivy-sbom-scan/0.1/`

**Step 1: Create directory structure**

```bash
mkdir -p managed-context/tasks/trivy-sbom-scan/0.1
```

**Step 2: Verify directory created**

Run: `ls -la managed-context/tasks/trivy-sbom-scan/0.1/`

Expected: Empty directory

**Step 3: Commit directory structure**

```bash
git add managed-context/tasks/trivy-sbom-scan/
git commit -s -m "chore: create trivy-sbom-scan task directory

Add task directory structure for trivy-based vulnerability scanning.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
Assisted-by: Cursor AI"
```

---

## Task 3: Create Trivy Task YAML - Metadata and Parameters

**Files:**
- Create: `managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml`

**Step 1: Write task metadata and parameters**

Create file with:
```yaml
---
apiVersion: tekton.dev/v1
kind: Task
metadata:
  labels:
    app.kubernetes.io/version: "0.1"
  annotations:
    tekton.dev/pipelines.minVersion: "0.12.1"
    tekton.dev/tags: "konflux"
  name: trivy-sbom-scan
spec:
  description: >-
    Scans container images for vulnerabilities using Trivy, analyzing container components against Trivy's vulnerability databases.
  params:
    - name: image-digest
      description: Image digest to scan.
    - name: image-url
      description: Image URL.
    - name: image-platform
      description: The platform built by.
      default: ""
    - name: ca-trust-config-map-name
      type: string
      description: The name of the ConfigMap to read CA bundle data from.
      default: trusted-ca
    - name: ca-trust-config-map-key
      type: string
      description: The name of the key in the ConfigMap that contains the CA bundle data.
      default: ca-bundle.crt
  results:
    - name: TEST_OUTPUT
      description: Tekton task test output.
    - name: SCAN_OUTPUT
      description: Trivy scan result.
    - name: IMAGES_PROCESSED
      description: Images processed in the task.
    - name: REPORTS
      description: Mapping of image digests to report digests
  stepTemplate:
    volumeMounts:
      - name: trusted-ca
        mountPath: /etc/pki/tls/certs/ca-custom-bundle.crt
        subPath: ca-bundle.crt
        readOnly: true
  steps:
```

**Step 2: Validate YAML syntax**

Run: `yq eval '.' managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml > /dev/null && echo "YAML valid"`

Expected: `YAML valid`

**Step 3: Commit task skeleton**

```bash
git add managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml
git commit -s -m "feat: add trivy-sbom-scan task metadata

Add Tekton task metadata, parameters, and results definition
following ADR/0030 naming conventions.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
Assisted-by: Cursor AI"
```

---

## Task 4: Add Step 1 - Get Image Manifests

**Files:**
- Modify: `managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml` (append to steps array)

**Step 1: Add get-image-manifests step**

Append to steps array (after `steps:` line):
```yaml
    - name: get-image-manifests
      image: quay.io/konflux-ci/konflux-test:v1.4.39@sha256:89cdc9d251e15d07018548137b4034669df8e9e2b171a188c8b8201d3638cb17
      computeResources:
        limits:
          memory: 512Mi
        requests:
          memory: 256Mi
          cpu: 100m
      env:
        - name: IMAGE_URL
          value: $(params.image-url)
        - name: IMAGE_DIGEST
          value: $(params.image-digest)
      securityContext:
        capabilities:
          add:
            - SETFCAP
      script: |
        #!/usr/bin/env bash
        set -euo pipefail
        # shellcheck source=/dev/null
        . /utils.sh

        imagewithouttag=$(echo -n $IMAGE_URL | sed "s/\(.*\):.*/\1/")
        imageanddigest=$(echo $imagewithouttag@$IMAGE_DIGEST)
        echo "Inspecting raw image manifest $imageanddigest."

        # Get the arch and image manifests by inspecting the image
        image_manifests=$(get_image_manifests -i "${imageanddigest}")
        if [ -n "$image_manifests" ]; then
          echo "$image_manifests" | jq -r 'to_entries[] | "\(.key) \(.value)"' | while read -r arch arch_sha; do
            echo "$arch_sha" > /tekton/home/image-manifest-$arch.sha
          done
        else
          echo "Failed to get image manifests from image \"$imageanddigest\""
          note="Task $(context.task.name) failed: Failed to get image manifests from image \"$imageanddigest\". For details, check Tekton task log."
          ERROR_OUTPUT=$(make_result_json -r "ERROR" -t "$note")
          echo "${ERROR_OUTPUT}" | tee "$(results.TEST_OUTPUT.path)"
          exit 0
        fi
```

**Step 2: Validate YAML**

Run: `yq eval '.spec.steps[0].name' managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml`

Expected: `get-image-manifests`

**Step 3: Commit manifest step**

```bash
git add managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml
git commit -s -m "feat: add get-image-manifests step to trivy task

Add first step to extract image manifests for multi-arch support.
Reuses konflux-test utilities and patterns from clair-scan.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
Assisted-by: Cursor AI"
```

---

## Task 5: Add Step 2 - Scan with Trivy

**Files:**
- Modify: `managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml` (append to steps array)

**Step 1: Add scan-with-trivy step**

Append to steps array:
```yaml
    - name: scan-with-trivy
      image: ghcr.io/aquasecurity/trivy:latest@sha256:e2b22eac59c02003d8749f5b8d9bd073b62e30fefaef5b7c8371204e0a4b0c08
      computeResources:
        limits:
          memory: 4Gi
        requests:
          memory: 1Gi
          cpu: 500m
      env:
        - name: IMAGE_URL
          value: $(params.image-url)
        - name: IMAGE_DIGEST
          value: $(params.image-digest)
        - name: IMAGE_PLATFORM
          value: $(params.image-platform)
      workingDir: /tekton/home
      script: |
        #!/usr/bin/env sh
        set -eu

        imagewithouttag=$(echo -n $IMAGE_URL | sed "s/\(.*\):.*/\1/")
        images_processed_template='{"image": {"pullspec": "'"$IMAGE_URL"'", "digests": [%s]}}'
        digests_processed=""

        run_trivy_on_arch() {
          arch="$1"
          sha_file="image-manifest-$arch.sha"

          if [ -e "$sha_file" ]; then
            arch_sha=$(cat "$sha_file")
            digest="${imagewithouttag}@${arch_sha}"

            echo "Running trivy on $arch image manifest..."
            trivy image --format json --scanners vuln --quiet "$digest" > "trivy-report-$arch.json" 2>/dev/null || true

            if [ -n "$digests_processed" ]; then
              digests_processed="${digests_processed}, \"$arch_sha\""
            else
              digests_processed="\"$arch_sha\""
            fi
          fi
        }

        platform="$IMAGE_PLATFORM"

        # If platform specified, extract architecture and run trivy on that manifest
        if [ -n "$platform" ]; then
          arch="${platform#*/}"
          case "$arch" in
            x86_64|local|localhost) arch="amd64" ;;
          esac
          case "$arch" in
            amd64|ppc64le|arm64|s390x)
              run_trivy_on_arch "$arch"
              ;;
            *)
              echo "Error: Unsupported architecture: '$arch'"
              exit 0
              ;;
          esac
        else
          # No platform specified, run on all available manifests
          for sha_file in image-manifest-*.sha; do
            if [ -e "$sha_file" ]; then
              arch=$(basename "$sha_file" | sed 's/image-manifest-//;s/.sha//')
              run_trivy_on_arch "$arch"
            fi
          done
        fi

        # Add image index digest if not already in list
        case "$digests_processed" in
          *"$IMAGE_DIGEST"*) ;;
          *) digests_processed="${digests_processed}, \"$IMAGE_DIGEST\"" ;;
        esac

        images_processed=$(echo "${images_processed_template}" | sed "s/%s/$digests_processed/")
        echo "$images_processed" > images-processed.json
```

**Step 2: Validate step added**

Run: `yq eval '.spec.steps[1].name' managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml`

Expected: `scan-with-trivy`

**Step 3: Commit trivy scanning step**

```bash
git add managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml
git commit -s -m "feat: add scan-with-trivy step

Add trivy vulnerability scanning for each architecture.
Generates trivy-report-{arch}.json files for OCI attachment.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
Assisted-by: Cursor AI"
```

---

## Task 6: Add Step 3 - Attach Reports to OCI

**Files:**
- Modify: `managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml` (append to steps array)

**Step 1: Add oci-attach-report step**

Append to steps array:
```yaml
    - name: oci-attach-report
      image: quay.io/konflux-ci/oras:latest@sha256:4542f5a2a046ca36653749a8985e46744a5d2d36ee10ca14409be718ce15129e
      workingDir: /tekton/home
      env:
        - name: IMAGE_URL
          value: $(params.image-url)
      script: |
        #!/usr/bin/env bash
        set -euo pipefail

        if ! compgen -G "trivy-report-*.json" > /dev/null; then
          echo 'No Trivy reports generated. Skipping upload.'
          exit 0
        fi

        echo "Selecting auth"
        select-oci-auth "$IMAGE_URL" > "$HOME/auth.json"

        repository="${IMAGE_URL/:*/}"

        arch() {
          report_file="$1"
          arch="${report_file/*-}"
          echo "${arch/.json/}"
        }

        MEDIA_TYPE='application/vnd.trivy.report+json'

        reports_json=""
        for f in trivy-report-*.json; do
          digest=$(cat "image-manifest-$(arch "$f").sha")
          image_ref="${repository}@${digest}"
          echo "Attaching $f to ${image_ref}"
          if ! report_digest="$(oras attach --no-tty --format go-template='{{.digest}}' --registry-config \
            "$HOME/auth.json" --artifact-type "${MEDIA_TYPE}" "${image_ref}" "$f:${MEDIA_TYPE}")"
          then
            echo "Failed to attach ${f} to ${image_ref}"
            exit 1
          fi
          # shellcheck disable=SC2016
          reports_json="$(yq --output-format json --indent=0 eval-all '. as $i ireduce ({}; . * $i)' <(echo "${reports_json}") <(echo "${digest}: ${report_digest}"))"
        done
        echo "${reports_json}" > reports.json
```

**Step 2: Validate step added**

Run: `yq eval '.spec.steps[2].name' managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml`

Expected: `oci-attach-report`

**Step 3: Commit OCI attachment step**

```bash
git add managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml
git commit -s -m "feat: add oci-attach-report step

Attach trivy reports to images via OCI for Conforma policy
evaluation. Uses custom MIME type for trivy reports.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
Assisted-by: Cursor AI"
```

---

## Task 7: Add Step 4 - Aggregate Results

**Files:**
- Modify: `managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml` (append to steps array)

**Step 1: Add aggregate-results step**

Append to steps array:
```yaml
    - name: aggregate-results
      image: quay.io/konflux-ci/konflux-test:v1.4.39@sha256:89cdc9d251e15d07018548137b4034669df8e9e2b171a188c8b8201d3638cb17
      computeResources:
        limits:
          memory: 2Gi
        requests:
          memory: 256Mi
          cpu: 100m
      securityContext:
        capabilities:
          add:
            - SETFCAP
      script: |
        #!/usr/bin/env bash
        set -euo pipefail
        . /utils.sh
        trap 'handle_error $(results.TEST_OUTPUT.path)' EXIT

        trivy_result_files=$(ls /tekton/home/trivy-report-*.json 2>/dev/null || echo "")
        if [ -z "$trivy_result_files" ]; then
          echo "Previous step [scan-with-trivy] failed: No trivy-report files found."
          note="Task $(context.task.name) failed: No trivy reports generated. For details, check Tekton task log."
          ERROR_OUTPUT=$(make_result_json -r "ERROR" -t "$note")
          echo "${ERROR_OUTPUT}" | tee "$(results.TEST_OUTPUT.path)"
          exit 0
        fi

        # Initialize counters
        scan_result='{"vulnerabilities":{"critical":0, "high":0, "medium":0, "low":0, "unknown":0}, "unpatched_vulnerabilities":{"critical":0, "high":0, "medium":0, "low":0, "unknown":0}}'

        for file in /tekton/home/trivy-report-*.json; do
          if [ ! -s "$file" ]; then
            echo "Warning: $file is empty, skipping"
            continue
          fi

          # Aggregate total vulnerabilities by severity
          result=$(jq -r '
            {
              vulnerabilities: {
                critical: ([.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length),
                high: ([.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length),
                medium: ([.Results[]?.Vulnerabilities[]? | select(.Severity=="MEDIUM")] | length),
                low: ([.Results[]?.Vulnerabilities[]? | select(.Severity=="LOW")] | length),
                unknown: ([.Results[]?.Vulnerabilities[]? | select(.Severity=="UNKNOWN")] | length)
              },
              unpatched_vulnerabilities: {
                critical: ([.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL" and (.Status=="affected" or .FixedVersion==null))] | length),
                high: ([.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH" and (.Status=="affected" or .FixedVersion==null))] | length),
                medium: ([.Results[]?.Vulnerabilities[]? | select(.Severity=="MEDIUM" and (.Status=="affected" or .FixedVersion==null))] | length),
                low: ([.Results[]?.Vulnerabilities[]? | select(.Severity=="LOW" and (.Status=="affected" or .FixedVersion==null))] | length),
                unknown: ([.Results[]?.Vulnerabilities[]? | select(.Severity=="UNKNOWN" and (.Status=="affected" or .FixedVersion==null))] | length)
              }
            }' "$file")

          # Aggregate across all architectures
          scan_result=$(jq -s '
            .[0].vulnerabilities.critical += .[1].vulnerabilities.critical |
            .[0].vulnerabilities.high += .[1].vulnerabilities.high |
            .[0].vulnerabilities.medium += .[1].vulnerabilities.medium |
            .[0].vulnerabilities.low += .[1].vulnerabilities.low |
            .[0].vulnerabilities.unknown += .[1].vulnerabilities.unknown |
            .[0].unpatched_vulnerabilities.critical += .[1].unpatched_vulnerabilities.critical |
            .[0].unpatched_vulnerabilities.high += .[1].unpatched_vulnerabilities.high |
            .[0].unpatched_vulnerabilities.medium += .[1].unpatched_vulnerabilities.medium |
            .[0].unpatched_vulnerabilities.low += .[1].unpatched_vulnerabilities.low |
            .[0].unpatched_vulnerabilities.unknown += .[1].unpatched_vulnerabilities.unknown |
            .[0]' <<<"$scan_result $result")
        done

        echo "$scan_result" | tee "$(results.SCAN_OUTPUT.path)"

        cat /tekton/home/images-processed.json | tee "$(results.IMAGES_PROCESSED.path)"
        cat /tekton/home/reports.json > "$(results.REPORTS.path)"

        note="Task $(context.task.name) completed: Refer to Tekton task result SCAN_OUTPUT for vulnerabilities scanned by Trivy."
        TEST_OUTPUT=$(make_result_json -r "SUCCESS" -t "$note")
        echo "${TEST_OUTPUT}" | tee "$(results.TEST_OUTPUT.path)"
```

**Step 2: Validate step added**

Run: `yq eval '.spec.steps[3].name' managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml`

Expected: `aggregate-results`

**Step 3: Commit aggregation step**

```bash
git add managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml
git commit -s -m "feat: add aggregate-results step

Parse trivy JSON reports and aggregate vulnerability counts by
severity. Separate patched vs unpatched. Output ADR/0030 results.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
Assisted-by: Cursor AI"
```

---

## Task 8: Add Volumes Section

**Files:**
- Modify: `managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml` (append volumes)

**Step 1: Add volumes section**

Append to end of file:
```yaml
  volumes:
  - name: trusted-ca
    configMap:
      name: $(params.ca-trust-config-map-name)
      items:
        - key: $(params.ca-trust-config-map-key)
          path: ca-bundle.crt
      optional: true
```

**Step 2: Validate complete task**

Run: `kubectl apply --dry-run=client -f managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml`

Expected: `task.tekton.dev/trivy-sbom-scan created (dry run)`

**Step 3: Commit volumes**

```bash
git add managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml
git commit -s -m "feat: add volumes for CA trust

Add trusted-ca configmap volume for TLS certificate validation.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
Assisted-by: Cursor AI"
```

---

## Task 9: Update Required Tasks Policy

**Files:**
- Modify: `managed-context/policies/ec-policy-data/data/required_tasks.yml:32`

**Step 1: Read current required tasks**

Run: `grep -A5 "required-tasks:" managed-context/policies/ec-policy-data/data/required_tasks.yml`

Expected output showing clair-scan as required

**Step 2: Change clair-scan to allow alternatives**

Change line 32 from:
```yaml
      - clair-scan
```

To:
```yaml
      - [clair-scan, trivy-sbom-scan]
```

Also update line 11 in pipeline-required-tasks docker section:
```yaml
        - [clair-scan, trivy-sbom-scan]
```

And line 21 in pipeline-required-tasks generic section:
```yaml
        - [clair-scan, trivy-sbom-scan]
```

**Step 3: Validate YAML**

Run: `yq eval '.' managed-context/policies/ec-policy-data/data/required_tasks.yml > /dev/null && echo "YAML valid"`

Expected: `YAML valid`

**Step 4: Commit policy update**

```bash
git add managed-context/policies/ec-policy-data/data/required_tasks.yml
git commit -s -m "feat: allow trivy-sbom-scan as alternative to clair

Update required tasks policy to accept either clair-scan or
trivy-sbom-scan for vulnerability scanning compliance.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
Assisted-by: Cursor AI"
```

---

## Task 10: Manual Testing

**Files:**
- None (verification only)

**Step 1: Validate task definition**

Run: `kubectl apply --dry-run=client -f managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml`

Expected: `task.tekton.dev/trivy-sbom-scan created (dry run)`

**Step 2: Check task has all required elements**

Run: `yq eval '.spec | keys' managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml`

Expected output including: `description`, `params`, `results`, `steps`, `stepTemplate`, `volumes`

**Step 3: Verify all 4 steps present**

Run: `yq eval '.spec.steps[].name' managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml`

Expected:
```
get-image-manifests
scan-with-trivy
oci-attach-report
aggregate-results
```

**Step 4: Verify ADR/0030 results**

Run: `yq eval '.spec.results[].name' managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml`

Expected:
```
TEST_OUTPUT
SCAN_OUTPUT
IMAGES_PROCESSED
REPORTS
```

**Step 5: Test trivy locally on sample image**

Run: `podman run --rm ghcr.io/aquasecurity/trivy:latest@sha256:e2b22eac59c02003d8749f5b8d9bd073b62e30fefaef5b7c8371204e0a4b0c08 image --format json --scanners vuln --quiet quay.io/konflux-ci/git-clone:latest | jq -r '.Results[0].Vulnerabilities | length'`

Expected: Number greater than 0 (showing vulnerabilities found)

---

## Task 11: Create README Documentation

**Files:**
- Create: `managed-context/tasks/trivy-sbom-scan/0.1/README.md`

**Step 1: Create README**

```markdown
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
3. **convert-to-clair-format**: Convert trivy reports to clair-compatible format
4. **oci-attach-report**: Attach detailed reports to image via OCI
5. **aggregate-results**: Parse and aggregate vulnerability counts

## Policy Integration

Reports are attached to images with MIME type `application/vnd.trivy.report+json` for later retrieval by Conforma during policy evaluation.
```

**Step 2: Commit README**

```bash
git add managed-context/tasks/trivy-sbom-scan/0.1/README.md
git commit -s -m "docs: add trivy-sbom-scan README

Document task parameters, results, usage, and architecture.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
Assisted-by: Cursor AI"
```

---

## Task 12: Final Verification and Summary

**Files:**
- None (verification only)

**Step 1: Verify all commits**

Run: `git log --oneline -12`

Expected: 12 commits related to trivy-sbom-scan implementation

**Step 2: Verify file structure**

Run: `find managed-context/tasks/trivy-sbom-scan -type f`

Expected:
```
managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml
managed-context/tasks/trivy-sbom-scan/0.1/README.md
```

**Step 3: Verify policy updates**

Run: `grep -n "trivy" managed-context/policies/ec-policy-data/data/rule_data.yml managed-context/policies/ec-policy-data/data/required_tasks.yml`

Expected: Lines showing trivy in both files

**Step 4: Count lines in task file**

Run: `wc -l managed-context/tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml`

Expected: ~270-300 lines

**Step 5: Generate implementation summary**

Create summary showing:
- ✅ Task created with 4 steps
- ✅ Policy updated to allow trivy image
- ✅ Required tasks updated to allow alternative
- ✅ README documentation added
- ✅ All commits have sign-off
- ✅ Follows ADR/0030 conventions
- ✅ Compatible with ARM/macOS

---

## Success Criteria

- [ ] Task validates with kubectl dry-run
- [ ] All 4 steps present and correctly ordered
- [ ] Results match ADR/0030 naming conventions
- [ ] Policy allows trivy image
- [ ] Required tasks accept trivy as alternative to clair
- [ ] README documents usage and integration
- [ ] All commits signed off
- [ ] Trivy can run locally and produce output

## Notes

- Task is NOT a trusted task (in managed-context for organization, not security boundary)
- Trivy image pinned to specific digest for reproducibility
- Multi-arch support matches clair-scan patterns
- OCI attachment enables Conforma policy evaluation
- Unpatched vulnerabilities identified by Status="affected" or FixedVersion=null
