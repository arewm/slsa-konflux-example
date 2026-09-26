# CI Workload Identity: Beyond Ambient Authority

CI/CD pipelines commonly run all tasks under a shared identity: one ambient credential signs SBOMs, reports vulnerability scans, and pushes container images. 

Standard workload identities establish execution context—a cluster, namespace, node, or service account. But location does not establish authorization. When every task in a pipeline shares the same service account, any compromised step can act with the full authority of the pipeline.

This document describes how to bind admission-time task verification to fine-grained cryptographic workload identities (SPIFFE/SPIRE), and details five production patterns that replace ambient authority with role-scoped capabilities.

---

## The Core Mechanism: From Location to Role

In Kubernetes-native CI systems like Tekton, pipelines typically run under a shared `ServiceAccount`. That creates three concrete security flaws:

1. **Ambient push authority**: Every task shares the same container registry credential (`regcred`). A compromised dependency-fetch step or linter can overwrite production image tags.
2. **Coarse attestation provenance**: Keyless signing tokens prove only that a container ran under a given namespace and service account (`sub: system:serviceaccount:<ns>:<sa>`). They do not establish whether the container was an authorized builder or an unvetted script.
3. **Premature release authority**: Tasks executing early in a release pipeline have ambient access to release-signing keys before policy evaluation runs.

### The Admission-to-Identity Binding

The solution binds admission verification directly to workload identity issuance:

```
PipelineRun submitted
        │
        ▼
┌────────────────────────────────────────┐
│ 1. TaskRun Creation                    │
│    spec.taskRef: pinned OCI bundle     │
└───────────────────┬────────────────────┘
                    │
                    ▼
┌────────────────────────────────────────┐
│ 2. Admission Gate (Kyverno)            │
│    • Matches trusted catalog pattern   │
│    • Enforces digest pin (@sha256:...) │
│    • Verifies Cosign bundle signature  │
│    Mutates: trusted-task-role: prod/dev│
└───────────────────┬────────────────────┘
                    │
                    ▼
┌────────────────────────────────────────┐
│ 3. Pod Execution (Tekton)              │
│    • Tekton propagates labels to Pod   │
│    • Mounts SPIFFE CSI agent socket    │
│    • Admission blocks bare pod spoofing│
└───────────────────┬────────────────────┘
                    │
                    ▼
┌────────────────────────────────────────┐
│ 4. Workload Identity (SPIRE)           │
│    Matches verified Pod labels:        │
│    prod ➔ spiffe://domain/trusted/...  │
│    dev  ➔ spiffe://domain/dev/...      │
└────────────────────────────────────────┘
```

Because Tekton natively propagates TaskRun metadata and labels to task pods, SPIRE can mint a SPIFFE ID that encodes the verified trust classification, service account, and task role:

```text
spiffe://konflux-ci.dev/trusted/{cluster}/{service-account}/{task-name}
```

### Trust Invariants

This model relies on two foundational controls:
- **Tamper-proof labels**: The `prevent-pod-label-spoofing` Kyverno policy rejects any pod carrying `trusted-task-role` unless its `ownerReferences` trace directly to an admitted `TaskRun`. Tenant workloads cannot self-assign trusted roles.
- **Immutable references**: Catalog tasks must be pinned by cryptographic digest (`@sha256:...`) and signed by an authorized release key. Mutable tags receive `trusted-task-role: dev`.

Once issued, downstream verifiers and external services evaluate *who* is making the request, without re-parsing raw pipeline history or re-verifying catalog signatures.

---

## Pattern 1: Separation of Duties for Attestations

### Problem
When signing credentials belong to the pipeline's service account, any task can sign any in-toto statement. A compromised build step can execute a fabricated vulnerability scan, generate a report claiming zero findings, sign it with ambient pipeline authority, and publish it to the registry. Outside verifiers accept the valid signature without knowing which container generated the claim.

### Identity & Mechanism
Each task retrieves a short-lived JWT-SVID from the SPIFFE Workload API (`/spiffe-workload-api/spire-agent.sock`) and exchanges it with Fulcio for an ephemeral X.509 code-signing certificate. Fulcio validates the JWT against SPIRE's OIDC discovery endpoint and records the task's SPIFFE ID in the certificate's `Subject Alternative Name (SAN)`:

- Builder task (`buildah-oci-ta`):
  `spiffe://konflux-ci.dev/trusted/kind-konflux/default/buildah-oci-ta`
- Scanner task (`trivy-sbom-scan`):
  `spiffe://konflux-ci.dev/trusted/kind-konflux/default/trivy-sbom-scan`

### Enforcement
Conforma (or any OPA/Rego policy engine) evaluates the signing certificate SAN in the attestation's cryptographic envelope:

```rego
# demo/manifests/separation_of_duties.rego
package policy.separation_of_duties
import rego.v1

# Deny when a CVE scan report is not signed by a trusted scanner role
deny contains msg if {
    some attestation in input.attestations
    attestation.statement.predicateType == "https://aquasecurity.github.io/trivy/report/v1"
    some sig in attestation.signatures
    uri := sig.certificate.extensions.subjectAlternativeName
    not regex.match("^spiffe://konflux-ci.dev/trusted/.*/trivy-sbom-scan$", uri)
    msg := sprintf("CVE scan report signed by unauthorized role: %s", [uri])
}

# Deny when build provenance is not signed by a trusted builder role
deny contains msg if {
    some attestation in input.attestations
    attestation.statement.predicateType == "https://slsa.dev/provenance/v0.2"
    some sig in attestation.signatures
    uri := sig.certificate.extensions.subjectAlternativeName
    not regex.match("^spiffe://konflux-ci.dev/trusted/.*/buildah-oci-ta$", uri)
    msg := sprintf("Build provenance signed by unauthorized role: %s", [uri])
}
```

### Failure Behavior
If a builder task signs a vulnerability scan, Conforma flags an unauthorized role violation and blocks release promotion.

---

## Pattern 2: Federated OCI Push Gating

### Problem
Pipelines routinely mount static registry credentials (`regcred`) into the shared build namespace. Any task sharing the service account can push images or overwrite existing tags.

### Identity & Mechanism
Static credentials are removed from the tenant namespace. The container registry (such as upstream Zot, Quay, or Harbor) enables OIDC Bearer authentication against SPIRE's OIDC Discovery Provider (`https://spire-spiffe-oidc-discovery-provider...`).

Zot access control rules restrict write actions to the builder's verified SPIFFE identity:

```json
{
  "http": {
    "auth": {
      "bearer": {
        "realm": "https://spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local",
        "service": "registry-service.kind-registry",
        "certificateAuthority": "/etc/zot/spire-ca.crt"
      }
    }
  },
  "accessControl": {
    "repositories": {
      "slsa-e2e-test": {
        "policies": [
          {
            "users": [
              "spiffe://konflux-ci.dev/trusted/kind-konflux/default/buildah-oci-ta"
            ],
            "actions": ["read", "create", "update"]
          }
        ]
      }
    }
  }
}
```

### Enforcement
1. `buildah-oci-ta` requests a JWT-SVID from the SPIFFE CSI socket with audience `registry-service.kind-registry`.
2. The task passes the token as a Bearer credential to `podman push` or `skopeo copy`.
3. Zot validates the token signature against SPIRE's JWKS and authorizes the push based on the `sub` claim.

### Failure Behavior
If an untrusted, unpinned, or inline task attempts to push, admission marks it `dev` (`spiffe://konflux-ci.dev/dev/...`). Zot evaluates the access policy and rejects the upload with **`403 Forbidden`**.

---

## Pattern 3: Secretless Internal Service Access

### Problem
Pipelines frequently query internal APIs: private vulnerability feeds, artifact metadata stores, or defect tracking systems. Operators commonly copy static API tokens into Kubernetes Secrets across every tenant namespace, creating credential sprawl and rotation overhead.

### Identity & Mechanism
Internal services mount zero secrets. Upon startup, the service loads public signing keys from SPIRE's JWKS endpoint (`https://spire-spiffe-oidc-discovery-provider.../keys`).

The task requests an audience-scoped JWT-SVID:

```bash
TOKEN=$(spire-agent api fetch jwt -audience https://cve-database.internal)
curl -H "Authorization: Bearer ${TOKEN}" https://cve-database.services.svc/api/v1/feed
```

### Enforcement
The service verifies the token signature against SPIRE's JWKS and extracts the `sub` claim. Access is granted only when `sub` matches the authorized role:

```python
# Service-side authorization verification
if claims.get("aud") != "https://cve-database.internal":
    return 401, "Invalid audience"
if not re.match(r"^spiffe://konflux-ci.dev/trusted/.+/trivy-sbom-scan$", claims.get("sub", "")):
    return 403, "Caller lacks scanner authorization"
return 200, vulnerability_feed
```

### Failure Behavior
Unauthorized workloads receive **`403 Forbidden`**. When a task pod completes, its ephemeral token expires automatically; no persistent secrets remain in the tenant namespace.

---

## Pattern 4: Cloud Workload Identity Federation

### Problem
Interacting with external cloud infrastructure (AWS ECR, GCP Artifact Registry, HashiCorp Vault) usually requires storing long-lived IAM access keys or service account JSON files in Kubernetes secrets.

### Identity & Mechanism
Because SPIRE serves standard OIDC discovery documents (`/.well-known/openid-configuration`), external cloud providers federate directly with SPIRE.

In AWS IAM, SPIRE is registered as an OIDC Identity Provider. An IAM role trust policy limits role assumption to the specific task identity:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::123456789012:oidc-provider/oidc.konflux-ci.dev"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.konflux-ci.dev:sub": "spiffe://konflux-ci.dev/trusted/prod-cluster/default/infra-deployer"
        }
      }
    }
  ]
}
```

### Enforcement
The task fetches a JWT-SVID with audience `sts.amazonaws.com` and exchanges it for temporary AWS credentials via `sts:AssumeRoleWithWebIdentity`.

### Failure Behavior
AWS evaluates the condition block. If another task in the same namespace calls STS, AWS rejects role assumption with an Access Denied error.

---

## Pattern 5: Release Gating and Ambient Authority

### Problem: The Ambient Release Authority Trap
In privileged release namespaces (`managed-tenant`), artifacts are verified, promoted, and certified with Verification Summary Attestations (VSAs).

Binding release signing authority to a Kubernetes ServiceAccount (`release-service-account`) creates an ambient authority trap: tasks like `collect-data` or `apply-mapping` share the service account with the final signing step. A compromised early task or modified workflow could sign a release VSA before `verify-conforma` runs.

### Model 2: Dual-Gated Conjunction (Implemented)
Model 2 enforces a control-plane conjunction between Kyverno admission and SPIRE attestation:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 1. Release Initiation                                                       │
│    PipelineRun slsa-e2e-release-dual-gated in managed-tenant                │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 2. Kyverno Admission Gate                                                   │
│    Labels TaskRuns in this pipeline:                                        │
│      trusted-pipeline-role: release-authority                               │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 3. SPIRE Attestation Conjunction Filter                                     │
│    ClusterSPIFFEID konflux-release-authority matches ONLY:                   │
│      • trusted-pipeline-role: release-authority                             │
│      • tekton.dev/pipelineTask: attach-summary-attestations                 │
│                                                                             │
│    • Early Tasks (collect-data, apply-mapping, verify-conforma):            │
│      pipelineTask != attach-summary-attestations ➔ NO SVID ISSUED            │
│                                                                             │
│    • Final Signing Task (attach-summary-attestations):                      │
│      Matches BOTH selectors ➔ Mints Release SVID:                           │
│      spiffe://konflux-ci.dev/release/{app}/{pipeline}                       │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 4. Keyless Signing into Rekor                                               │
│    Task exchanges SVID via Fulcio and signs VSA/SVR into Rekor.             │
└─────────────────────────────────────────────────────────────────────────────┘
```

Early tasks match the pipeline role, but fail the task selector. SPIRE issues no identity. Only `attach-summary-attestations` receives the release authority SVID.

### Model 3: Policy Clearance Tokens (Capability Gating)
Model 3 is an alternative data-plane design that avoids control-plane label matching:
1. `verify-conforma` evaluates policy rules against the build snapshot.
2. If all rules pass, it mints a short-lived **Clearance Token** (JWT) signed by the policy engine private key. The token claims include `verdict: PASSED`, `policy_hash`, `pipelinerun_uid`, and the target `image_digest`.
3. The token passes to `attach-summary-attestations` via an immutable Trusted Artifact OCI archive.
4. `attach-summary-attestations` presents both its workload identity and the clearance token to Fulcio.
5. Fulcio validates the policy clearance token before issuing a release signing certificate.

---

## Comparison: CI Identity Models

| Capability | Kubernetes SA | GitHub Actions / GitLab CI | Tekton + Kyverno + SPIRE |
| :--- | :--- | :--- | :--- |
| **Trust Anchor** | Cluster API Server | Platform OIDC Issuer | Self-hosted SPIRE Trust Domain |
| **Identity Granularity** | Namespace + ServiceAccount | Repo + Branch / Workflow | **Task Definition + Trust Level + Pod UID** |
| **Admission Checking** | None | SaaS Workflow Validation | **Cosign verification on catalog bundles** |
| **Separation of Duties** | Shared service-account token | Fixed platform claims | **Enforced by Rego policy on SPIFFE URI** |
| **Push Gating** | Static `regcred` secret | Reusable workflows | **Direct OIDC Bearer tokens to registry** |
| **Portability** | Kubernetes only | Locked to SaaS provider | **CNCF Standards (SPIFFE, Sigstore, OCI 1.1)** |

---

## Verification & Hands-On Demonstration

All five patterns are implemented and verified in this repository.

To run the interactive presentation demo:

```bash
# Initialize demo environment (deploys OIDC Zot, mock CVE service, and SPIRE)
./demo/setup-demo.sh

# Run the interactive live presentation runner (Acts 0 through 4)
./demo/run-demo.sh
```

For slide terminal integration via `ttyd`, see **[KubeCon Demo Guide](../../demo/README.md)** and **[Dual-Gated Release Guide](dual-gated-release.md)**.
