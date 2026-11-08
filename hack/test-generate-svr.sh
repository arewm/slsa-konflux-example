#!/bin/bash
# Test the generate-svr logic from attach-summary-attestations against
# sample Conforma reports from mild-to-wild-samples.
set -euo pipefail

MILD_TO_WILD="$HOME/workspace/src/github.com/arewm/mild-to-wild-samples"
PASS=0
FAIL=0

run_generate_svr() {
  local workdir="$1"
  local VSA_DIR="$workdir/vsa"
  local REPORT="$VSA_DIR/report-json.json"

  local INTERSECTED_CODES
  INTERSECTED_CODES=$(jq -r '
    [.components[] | [.successes[].metadata.code] | unique] as $sets |
    if ($sets | length) == 0 then []
    else
      reduce $sets[] as $s (
        $sets[0];
        . as $current | map(select(. as $code | $s | any(. == $code)))
      )
    end | .[]
  ' "$REPORT")

  local PROPERTIES=()
  local HAS_ALL_TASKS_TRUSTED=false
  local HAS_ALL_TASK_REFS_TRUSTED=false
  local HAS_SLSA_BUILDER_ID_ACCEPTED=false

  while IFS= read -r code; do
    [[ -z "$code" ]] && continue
    local NORMALIZED
    NORMALIZED=$(echo "$code" | tr '[:lower:]' '[:upper:]' | tr '.' '_')
    PROPERTIES+=("CONFORMA_${NORMALIZED}")
    case "$code" in
      wild.all_tasks_trusted)          HAS_ALL_TASKS_TRUSTED=true ;;
      wild.all_task_refs_trusted)      HAS_ALL_TASK_REFS_TRUSTED=true ;;
      slsa_build_build_service.slsa_builder_id_accepted) HAS_SLSA_BUILDER_ID_ACCEPTED=true ;;
    esac
  done <<< "$INTERSECTED_CODES"

  if [[ "$HAS_ALL_TASKS_TRUSTED" == "true" && "$HAS_ALL_TASK_REFS_TRUSTED" == "true" ]]; then
    PROPERTIES+=("SLSA_BUILD_LEVEL_3")
  elif [[ "$HAS_SLSA_BUILDER_ID_ACCEPTED" == "true" ]]; then
    PROPERTIES+=("SLSA_BUILD_LEVEL_2")
  fi

  local POLICIES TIME_CREATED PROPS_JSON
  POLICIES=$(jq '[.policy.sources[].policy[] | {"uri": .}]' "$REPORT")
  TIME_CREATED=$(jq -r '."effective-time" // (now | todate)' "$REPORT")
  PROPS_JSON=$(printf '%s\n' "${PROPERTIES[@]}" | jq -R . | jq -s .)

  jq -n \
    --argjson policies "$POLICIES" \
    --arg time_created "$TIME_CREATED" \
    --argjson properties "$PROPS_JSON" \
    '{
      "verifier": {"id": "https://conforma.dev/cli", "policies": $policies},
      "timeCreated": $time_created,
      "properties": $properties
    }' > "$VSA_DIR/svr.json"
}

check() {
  local label="$1" expr="$2" file="$3"
  if jq -e "$expr" "$file" > /dev/null 2>&1; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "       expr: $expr"
    echo "       actual: $(jq "$expr" "$file" 2>&1 || true)"
    FAIL=$((FAIL + 1))
  fi
}

# ── Test 1: medium report (GitHub Actions, no wild.* rules) ──────────────────
echo "=== Test 1: medium report (expect SLSA_BUILD_LEVEL_2) ==="
WORKDIR=$(mktemp -d)
mkdir -p "$WORKDIR/vsa"
cp "$MILD_TO_WILD/output/medium/conforma/built-report.json" "$WORKDIR/vsa/report-json.json"
run_generate_svr "$WORKDIR"
SVR="$WORKDIR/vsa/svr.json"

check "predicateType field absent (predicate-only output)"     '.predicateType | not'                       "$SVR"
check "verifier.id is conforma.dev/cli"                        '.verifier.id == "https://conforma.dev/cli"'  "$SVR"
check "verifier.policies is non-empty array"                   '.verifier.policies | (type == "array" and length > 0)' "$SVR"
check "timeCreated is present"                                 '.timeCreated | length > 0'                  "$SVR"
check "properties is non-empty array"                          '.properties | (type == "array" and length > 0)' "$SVR"
check "CONFORMA_BUILTIN_IMAGE_SIGNATURE_CHECK present"         '.properties | contains(["CONFORMA_BUILTIN_IMAGE_SIGNATURE_CHECK"])' "$SVR"
check "CONFORMA_BUILTIN_ATTESTATION_SIGNATURE_CHECK present"   '.properties | contains(["CONFORMA_BUILTIN_ATTESTATION_SIGNATURE_CHECK"])' "$SVR"
check "SLSA_BUILD_LEVEL_2 present"                             '.properties | contains(["SLSA_BUILD_LEVEL_2"])' "$SVR"
check "SLSA_BUILD_LEVEL_3 absent (no wild.* rules)"            '.properties | contains(["SLSA_BUILD_LEVEL_3"]) | not' "$SVR"
check "no raw codes (all values start with CONFORMA_ or SLSA_)" \
  '.properties | all(startswith("CONFORMA_") or startswith("SLSA_"))' "$SVR"
echo ""

# ── Test 2: wild report (Tekton + trusted tasks) ─────────────────────────────
echo "=== Test 2: wild report (expect SLSA_BUILD_LEVEL_3) ==="
WORKDIR=$(mktemp -d)
mkdir -p "$WORKDIR/vsa"
cp "$MILD_TO_WILD/output/wild/conforma/built-report.json" "$WORKDIR/vsa/report-json.json"
run_generate_svr "$WORKDIR"
SVR="$WORKDIR/vsa/svr.json"

check "verifier.id is conforma.dev/cli"      '.verifier.id == "https://conforma.dev/cli"'  "$SVR"
check "SLSA_BUILD_LEVEL_3 present"           '.properties | contains(["SLSA_BUILD_LEVEL_3"])' "$SVR"
check "SLSA_BUILD_LEVEL_2 absent"            '.properties | contains(["SLSA_BUILD_LEVEL_2"]) | not' "$SVR"
check "CONFORMA_WILD_ALL_TASKS_TRUSTED present" '.properties | contains(["CONFORMA_WILD_ALL_TASKS_TRUSTED"])' "$SVR"
check "no raw codes"  '.properties | all(startswith("CONFORMA_") or startswith("SLSA_"))' "$SVR"
echo ""

# ── Test 3: synthetic multi-component report (intersection) ──────────────────
echo "=== Test 3: multi-component report (intersection drops component-specific rules) ==="
WORKDIR=$(mktemp -d)
mkdir -p "$WORKDIR/vsa"

# Merge the medium and wild reports into a two-component report.
# medium has github_certificate.* rules; wild does not → those should drop out.
# wild has wild.* rules; medium does not → those should drop out.
# Common rules (builtin.*, slsa_build_build_service.*, slsa_source_*, mild.*, external_parameters.*)
# should remain.
jq -s '{
  "success": true,
  "components": [.[0].components[0] + {"name": "github-built"}, .[1].components[0] + {"name": "tekton-built"}],
  "policy": .[0].policy,
  "ec-version": .[0]["ec-version"],
  "effective-time": .[0]["effective-time"]
}' \
  "$MILD_TO_WILD/output/medium/conforma/built-report.json" \
  "$MILD_TO_WILD/output/wild/conforma/built-report.json" \
  > "$WORKDIR/vsa/report-json.json"

run_generate_svr "$WORKDIR"
SVR="$WORKDIR/vsa/svr.json"

check "CONFORMA_BUILTIN_IMAGE_SIGNATURE_CHECK present (common rule)"  \
  '.properties | contains(["CONFORMA_BUILTIN_IMAGE_SIGNATURE_CHECK"])' "$SVR"
check "CONFORMA_GITHUB_CERTIFICATE_GH_WORKFLOW_NAME absent (medium-only)"  \
  '.properties | contains(["CONFORMA_GITHUB_CERTIFICATE_GH_WORKFLOW_NAME"]) | not' "$SVR"
check "CONFORMA_WILD_ALL_TASKS_TRUSTED absent (wild-only)"  \
  '.properties | contains(["CONFORMA_WILD_ALL_TASKS_TRUSTED"]) | not' "$SVR"
check "no SLSA level (neither L2-only nor L3-only codes survive intersection, but L2 code is common)" \
  '.properties | contains(["SLSA_BUILD_LEVEL_2"])' "$SVR"
check "no raw codes"  '.properties | all(startswith("CONFORMA_") or startswith("SLSA_"))' "$SVR"
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
