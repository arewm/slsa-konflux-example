package policy.separation_of_duties_test
import rego.v1
import data.policy.separation_of_duties

test_legitimate_roles_allowed if {
    test_input := {
        "attestations": [
            {
                "statement": {"predicateType": "https://aquasecurity.github.io/trivy/report/v1"},
                "signatures": [{"certificate": {"extensions": {"subjectAlternativeName": "spiffe://konflux-ci.dev/trusted/kind-konflux/default/trivy-sbom-scan"}}}]
            },
            {
                "statement": {"predicateType": "https://slsa.dev/provenance/v0.2"},
                "signatures": [{"certificate": {"extensions": {"subjectAlternativeName": "spiffe://konflux-ci.dev/trusted/kind-konflux/default/buildah-oci-ta"}}}]
            }
        ]
    }
    count(separation_of_duties.deny) == 0 with input as test_input
}

test_builder_forging_cve_scan_denied if {
    test_input := {
        "attestations": [
            {
                "statement": {"predicateType": "https://aquasecurity.github.io/trivy/report/v1"},
                "signatures": [{"certificate": {"extensions": {"subjectAlternativeName": "spiffe://konflux-ci.dev/trusted/kind-konflux/default/buildah-oci-ta"}}}]
            }
        ]
    }
    count(separation_of_duties.deny) == 1 with input as test_input
}
