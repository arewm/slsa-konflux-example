#
# METADATA
# title: SBOM attestation required
# description: >-
#   Verify that at least one SBOM attestation (SPDX or CycloneDX) exists
#   for the built artifact. SBOM generation is required for supply chain
#   transparency.
# custom:
#   short_name: sbom_exists
#   failure_msg: No SBOM attestation found for the built artifact
#   collections:
#     - slsa_source
#
package custom.sbom_required

import rego.v1

import data.lib
import data.lib.tkn

# SBOM predicate types we accept
_sbom_predicate_types := {
	"https://spdx.dev/Document",
	"https://cyclonedx.org/bom",
	"https://cyclonedx.org/bom/v1.4",
	"https://cyclonedx.org/bom/v1.5",
}

# METADATA
# title: SBOM attestation exists
# description: >-
#   At least one SBOM attestation with a recognized predicate type must be
#   present among the build attestations. Accepted formats are SPDX and
#   CycloneDX (v1.4 and v1.5).
# custom:
#   short_name: sbom_exists
#   failure_msg: No SBOM attestation found for the built artifact
#   solution: >-
#     Ensure the build pipeline includes a task that generates an SBOM
#     attestation in SPDX or CycloneDX format and attaches it to the
#     built image.
#   collections:
#     - slsa_source
#
deny contains result if {
	# Collect all attestations whose predicateType is a known SBOM type
	sbom_attestations := [att |
		some att in input.attestations
		att.statement.predicateType in _sbom_predicate_types
	]
	count(sbom_attestations) == 0
	result := lib.result_helper(rego.metadata.chain(), [])
}
