Platform-controlled components for the managed trust boundary. Everything here runs in the managed namespace with access to signing keys and policy evaluation.

## Tasks

tasks/verify-conforma/0.1/verify-conforma-vsa.yaml 491L — Policy evaluation via Conforma, gates release pipeline
tasks/attach-vsa/0.1/attach-vsa.yaml 437L — Generates and signs Verification Summary Attestations
tasks/apply-mapping/apply-mapping.yaml 626L — Maps artifacts to destination registries
tasks/trivy-sbom-scan/0.1/trivy-sbom-scan.yaml 348L — SBOM vulnerability scanning via Trivy
tasks/extract-oci-storage/extract-oci-storage.yaml 44L — Extracts OCI storage references

## Pipelines

pipelines/slsa-e2e-release/slsa-e2e-release.yaml 467L — Release pipeline definition (verify-conforma → apply-mapping → push-snapshot → attach-vsa)
slsa-e2e-pipeline/slsa-e2e-pipeline.yaml 402L — Build pipeline definition (custom SLSA e2e pipeline bundle)
slsa-e2e-pipeline/bundle-ref 1L — Pinned pipeline bundle reference (updated by hack/build-pipeline.sh)

## Policies

policies/ec-policy-data/data/rule_data.yml 239L — CVE leeway, required labels, allowed registries, release schedule
policies/ec-policy-data/data/required_tasks.yml 37L — Tasks required in build pipeline for policy pass
policies/ec-policy-data/policy/custom/slsa_source_verification/slsa_source_verification.rego 268L — Source track level enforcement (4 rules)
policies/ec-policy-data/tests/slsa_source_verification/slsa_source_verification_test.rego 326L — Rego unit tests for source verification policy
