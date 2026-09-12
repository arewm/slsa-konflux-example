package policy.separation_of_duties
import rego.v1

# Deny when a CVE scan report is not signed by a trusted scanner role
deny contains msg if {
    some attestation in input.attestations
    attestation.statement.predicateType == "https://aquasecurity.github.io/trivy/report/v1"
    some sig in attestation.signatures
    uri := sig.certificate.extensions.subjectAlternativeName
    not regex.match("^spiffe://konflux-ci.dev/trusted/.*/trivy-sbom-scan$", uri)
    msg := sprintf("CVE scan report signed by unauthorized role: %s (expected scanner role)", [uri])
}

# Deny when build provenance is not signed by a trusted builder role
deny contains msg if {
    some attestation in input.attestations
    attestation.statement.predicateType == "https://slsa.dev/provenance/v0.2"
    some sig in attestation.signatures
    uri := sig.certificate.extensions.subjectAlternativeName
    not regex.match("^spiffe://konflux-ci.dev/trusted/.*/buildah-oci-ta$", uri)
    msg := sprintf("Build provenance signed by unauthorized role: %s (expected builder role)", [uri])
}
