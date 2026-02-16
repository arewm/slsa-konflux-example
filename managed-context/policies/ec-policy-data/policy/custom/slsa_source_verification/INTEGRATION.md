# SLSA Source Verification - Integration Guide

## Summary

Successfully created and tested a custom Conforma policy for SLSA source track verification.

## ✅ What Was Created

### Policy Files
```
managed-context/policies/ec-policy-data/
├── policy/custom/slsa_source_verification/
│   ├── slsa_source_verification.rego         # Main policy (228 lines)
│   ├── slsa_source_verification_test.rego    # Test suite (13 tests, all passing)
│   ├── README.md                              # User documentation
│   └── INTEGRATION.md                         # This file
├── data/rule_data.yml                          # Updated with slsa_source_min_level: "3"
└── test_policy.sh                              # Test runner script
```

### Policy Features

**4 validation rules in the `@slsa_source` collection:**

1. **`required_level_achieved`**
   - Validates `SLSA_SOURCE_LEVEL_ACHIEVED` result meets minimum requirement
   - Defaults to level "1" if not specified in rule_data
   - Currently configured to require level "3"

2. **`result_provided`**
   - Ensures verify-source task provides required result

3. **`parameters_match_git_clone`**
   - Validates verify-source URL/REVISION match any git-clone task results
   - Handles URL normalization (.git suffix variations)
   - Supports multi-repository builds

4. **`verified_all_materials`**
   - Ensures verify-source ran for ALL git repositories in attestation
   - Critical for multi-repo build security

### Test Coverage

**13 test cases, all passing:**
- ✅ Level 3 achieves level 3 requirement
- ✅ Level 3 exceeds level 1 requirement (positive test)
- ✅ Level 2 exceeds level 1 requirement (positive test)
- ✅ Level 2 fails level 3 requirement
- ✅ Level 1 fails level 3 requirement
- ✅ Missing result detection
- ✅ URL mismatch detection (with material verification failure)
- ✅ Revision mismatch detection (with material verification failure)
- ✅ URL normalization (.git suffix handling)
- ✅ Multi-repo builds with complete verification
- ✅ Multi-repo builds with missing verification
- ✅ SLSA v0.2 attestation format
- ✅ SLSA v1.0 attestation format

## 🧪 Testing

Run tests:
```bash
cd ~/workspace/git/gh/slsa-konflux-example/managed-context/policies/ec-policy-data
./test_policy.sh
```

Expected output:
```
PASS: 249/249
```

## 🚀 Next Steps

### 1. Review Configuration

Current setting in `data/rule_data.yml`:
```yaml
slsa_source_min_level: "3"
```

**Options:**
- `"1"`: Version controlled (default if not specified)
- `"2"`: Version controlled + verified history
- `"3"`: Level 2 + retention/tamper resistance (current)

### 2. Update EnterpriseContractPolicy

Add to your ECP configuration (location will depend on your setup):

**Option A:** Update `resources/templates/enterprisecontractpolicy.yaml`

```yaml
spec:
  sources:
    - name: Release Policies
      policy:
        - oci::{{ .Values.release.policy.policyBundle }}
        # Add custom policy
        - {{ printf "%s//managed-context/policies/ec-policy-data/policy" (.Values.repositoryUrl | replace "https://github.com/" "github.com/") }}
      data:
        - {{ $policyData }}
      config:
        include:
          - '@slsa3'        # Build track
          - '@slsa_source'  # Source track (NEW!)
```

**Option B:** Test locally first

```bash
cd ~/workspace/git/gh/slsa-konflux-example
~/workspace/git/gh/conforma/cli/cli validate image \
  --policy managed-context/policies/ec-policy-data/policy \
  --data managed-context/policies/ec-policy-data/data \
  --include '@slsa_source' \
  <your-image>
```

### 3. Ensure Pipeline Integration

Your pipelines must include verify-source task:

```yaml
- name: verify-source
  runAfter: [git-clone]
  taskRef:
    name: verify-source
  params:
    - name: URL
      value: $(tasks.git-clone.results.url)
    - name: REVISION
      value: $(tasks.git-clone.results.commit)
```

**For multi-repo builds:**
- Add one verify-source task per git-clone task
- Each verify-source must use results from its corresponding git-clone

### 4. Commit Changes

```bash
cd ~/workspace/git/gh/slsa-konflux-example
git add managed-context/policies/ec-policy-data/
git commit -m "Add SLSA source verification policy

Custom policy validates verify-source task execution:
- Requires SLSA source level 3 (configurable)
- Validates parameters match git-clone results
- Ensures all git materials are verified
- Supports multi-repo builds
- Defaults to level 1 if not configured

Test coverage: 13/13 passing

Assisted-by: Claude Code (Sonnet 4.5)"
```

## 📋 Behavior Details

### Multiple Error Reporting

When verify-source has incorrect parameters:
- **Both** parameter mismatch AND material verification errors are reported
- This is intentional - helps users understand both what's wrong and the security impact
- Fix the parameter issue first, material verification error will resolve automatically

### URL Normalization

The policy handles common Git URL variations:
- With/without `git+` prefix
- With/without `.git` suffix
- Trailing slashes

All of these are considered equivalent:
```
https://github.com/example/repo
https://github.com/example/repo.git
git+https://github.com/example/repo
git+https://github.com/example/repo.git
```

### Multi-Repository Support

For builds cloning multiple repositories:
1. Each repository appears in attestation materials
2. Each repository must have a corresponding verify-source task
3. Each verify-source must use parameters from the matching git-clone
4. Policy validates complete coverage - no repositories can be skipped

## 🐛 Troubleshooting

### Test Failures

If tests fail after modifications:
```bash
cd ~/workspace/git/gh/slsa-konflux-example/managed-context/policies/ec-policy-data
./test_policy.sh --verbose
```

### Policy Not Triggering

Check that:
1. `@slsa_source` collection is included in ECP config
2. Attestations have `buildType: "tekton.dev/v1/PipelineRun"`
3. verify-source task is actually present in attestation
4. git-clone task produces `url` and `commit` results

### False Positives

If policy incorrectly reports errors:
1. Check verify-source parameters use exact git-clone result references:
   - `$(tasks.git-clone.results.url)` not hardcoded URLs
   - `$(tasks.git-clone.results.commit)` not hardcoded SHAs
2. For multi-repo: ensure task names are unique (`git-clone-main`, `git-clone-lib`)

## 📚 Additional Resources

- [SLSA Source Requirements](https://slsa.dev/spec/v1.2/source-requirements)
- [verify-source Task Definition](https://github.com/konflux-ci/build-definitions/tree/main/task/verify-source/0.1)
- [Enterprise Contract Documentation](https://conforma.dev)
- Full policy documentation: `README.md` in this directory

## 🎯 Key Decisions

1. **Default level "1" not "3"**: Conservative default, users opt-in to stricter levels
2. **Separate `@slsa_source` collection**: Independent from build track (`@slsa3`)
3. **Multiple errors allowed**: Better user experience than hiding related issues
4. **URL normalization**: Handles common variations automatically
5. **Multi-repo validation**: Security-critical for complex builds
