# CI Workload Identity: Beyond Ambient Authority

You wouldn't ask a plumber to sign off on your electrical work. But in CI/CD pipelines, we do that kind of thing all the time. Most pipelines run under a single identity... one credential for signing SBOMs, reporting vulnerabilities, and pushing images alike.

Standard workload identities tell you where something ran (a namespace, a service account, a node). They don't tell you what the workload was actually authorized to do.

This document walks through what it looks like to close that gap by tying admission-time task verification to cryptographic workload identities (SPIFFE/SPIRE), and how that pattern extends across five concrete use cases.

---

## The Core Mechanism: From Location to Role

In Tekton or any Kubernetes-based runner, the pipeline usually runs under a shared `ServiceAccount`. That causes three distinct problems:

1. **Ambient push authority**: Every step shares the same `regcred`. A compromised linter or dependency-fetch script can overwrite a production image tag.
2. **Coarse attestations**: Keyless signing tokens prove only that a pod ran in `default-tenant:default`. They don't prove whether the pod was a build task or a vulnerability scanner.
3. **Overprivileged release gates**: Tasks running early in a release pipeline have ambient access to the release signing key before policy checks even run.

Here is how we wire admission verification to SPIFFE identity to stop that:

```
PipelineRun submitted
        │
        ▼
┌────────────────────────────────────────┐
│ 1. TaskRun Created                     │
│    spec.taskRef: pinned OCI bundle     │
└───────────────────┬────────────────────┘
                    │
                    ▼
┌────────────────────────────────────────┐
│ 2. Admission Gate (Kyverno)            │
│    • Matches trusted catalog pattern   │
│    • Checks digest pin (@sha256:...)   │
│    • Verifies Cosign bundle signature  │
│    Mutates: trusted-task-role: prod/dev│
└───────────────────┬────────────────────┘
                    │
                    ▼
┌────────────────────────────────────────┐
│ 3. Pod Execution (Tekton)              │
│    Tekton propagates labels to Pod     │
│    Mounts SPIFFE CSI agent socket      │
│    Admission blocks bare pod spoofing  │
└───────────────────┬────────────────────┘
                    │
                    ▼
┌────────────────────────────────────────┐
│ 4. Workload Identity (SPIRE)           │
│    Matches verified labels:            │
│    prod ➔ spiffe://domain/trusted/...  │
│    dev  ➔ spiffe://domain/dev/...      │
└────────────────────────────────────────┘
```

Because Tekton natively propagates `spec.taskRef` names and TaskRun labels down to task pods, SPIRE can mint a SPIFFE ID that encodes both the trust level and the task name:

```text
spiffe://konflux-ci.dev/trusted/{cluster}/{service-account}/{task-name}
```

Once a task has that identity, downstream verifiers and external services can check *who* is asking, without having to re-parse the pipeline's raw git history or re-verify catalog signatures.

---

## Use Case 1: Separation of Duties for Attestations

A signed attestation is only as good as the task that authored it.

If your pipeline signs everything with a single key or a shared namespace identity, a compromised build step can easily generate a fake vulnerability report claiming zero CVEs, sign it, and push it to the registry. To an outside consumer, the cryptographic signature checks out.

### How It Works

Tasks retrieve a short-lived JWT-SVID from the SPIFFE Workload API and exchange it with Fulcio for an ephemeral code-signing certificate. Fulcio places the SPIFFE ID into the certificate's Subject Alternative Name (SAN).

When `buildah-oci-ta` runs, its certificate SAN is:
```text
spiffe://konflux-ci.dev/trusted/kind-konflux/default/buildah-oci-ta
```

When `trivy-sbom-scan` runs, its certificate SAN is:
```text
spiffe://konflux-ci.dev/trusted/kind-konflux/default/trivy-sbom-scan
```

### Policy Enforcement

Conforma (or any OPA/Rego verifier) doesn't just check whether the attestation has a valid signature. It checks whether the identity in the certificate was authorized to author that predicate:

```rego
# demo/manifests/separation_of_duties.rego
package separation_of_duties

default allow = false

# Vulnerability scans must be signed by the scanner task
allow {
    input.predicateType == "https://aquasecurity.github.io/trivy/report/v1"
    regex.match("^spiffe://konflux-ci.dev/trusted/.+/trivy-sbom-scan$", input.signer_uri)
}

# SBOMs and provenance must be signed by the builder task
allow {
    input.predicateType == "https://spdx.dev/Document"
    regex.match("^spiffe://konflux-ci.dev/trusted/.+/buildah-oci-ta$", input.signer_uri)
}
```

If the builder task tries to sign a vulnerability scan, Conforma rejects it immediately.

---

## Use Case 2: Federated OCI Push Gating

Most CI systems mount a static `config.json` containing registry credentials into the build pod. Once that secret is in the namespace, any task that shares the ServiceAccount can push to the registry.

Instead of distributing static push tokens, we configure the registry to accept SPIFFE OIDC Bearer tokens.

### How It Works

Registries that support OIDC bearer authentication (like upstream Zot, Quay, or Harbor) can point directly to SPIRE's OIDC Discovery Provider (`https://spire-spiffe-oidc-discovery-provider...`).

Zot's access control configuration can then bind write permissions directly to the builder's SPIFFE ID:

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

During the build:
1. `buildah-oci-ta` requests a JWT-SVID from the SPIFFE Workload API with audience `registry-service.kind-registry`.
2. It passes that token as a bearer credential to `podman push` or `skopeo copy`.
3. Zot validates the token signature against SPIRE's keys and checks the `sub` claim.
4. If an untrusted, inline, or unverified task attempts to push, its identity is labeled `dev` (`spiffe://konflux-ci.dev/dev/...`). Zot immediately returns **`403 Forbidden`**.

No static registry credentials ever live in the tenant namespace.

---

## Use Case 3: Secretless Internal Service Access

Pipelines constantly need to reach internal services... vulnerability feeds, artifact metadata databases, Jira/GitLab instances, or internal mirror servers. Typically, someone copies an API token into a Kubernetes Secret in every tenant namespace.

With SPIFFE, the task presents an audience-scoped JWT instead.

### How It Works

Take a lightweight internal service like our mock CVE database:
1. The service mounts no secrets. When it starts up, it reads the public keys from SPIRE's JWKS endpoint (`https://spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local/keys`).
2. When `trivy-sbom-scan` needs the feed, it fetches a JWT-SVID for audience `https://cve-database.internal`:
   ```bash
   TOKEN=$(spire-agent api fetch jwt -audience https://cve-database.internal)
   curl -H "Authorization: Bearer ${TOKEN}" https://cve-database.services.svc/api/v1/feed
   ```
3. The service verifies the signature against SPIRE's keys, extracts `sub`, and checks authorization:
   - Caller is `.../trusted/.../trivy-sbom-scan` ➔ **`200 OK`**
   - Caller is `.../dev/...` or another task ➔ **`403 Forbidden`**

The secret rotation problem disappears... if a task pod is deleted, its token is gone.

---

## Use Case 4: Cloud Workload Identity Federation

The same pattern works outside the cluster. When tasks need to talk to AWS, GCP, or HashiCorp Vault, you don't need long-lived AWS access keys or GCP service account JSON files stored in Kubernetes secrets.

Because SPIRE exposes a standard OIDC discovery endpoint (`/.well-known/openid-configuration`), external cloud providers can federate with it directly.

### AWS IAM Example

Configure SPIRE as an IAM OIDC Identity Provider in AWS. Then create an IAM role with a trust policy that matches the specific task:

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

The task requests an AWS-audience JWT from SPIRE, calls `sts:AssumeRoleWithWebIdentity`, and receives temporary AWS credentials. If an arbitrary task in the same namespace tries the same call, AWS denies the role assumption.

---

## Use Case 5: Release Gating and Ambient Authority

In a release pipeline (`managed-tenant`), artifacts get verified, signed, and published. But if the signing key is bound to a ServiceAccount, you run into the **ambient release authority trap**:

Any early task running under that ServiceAccount (`collect-data`, `apply-mapping`) could sign a release attestation before `verify-conforma` finishes.

We looked at two ways to handle this:

### Model 2: Dual-Gated Identity (Implemented)

Model 2 uses admission mutation and SPIRE selectors together:
- Kyverno watches `TaskRun` creations in `managed-tenant`. If the pipeline matches `slsa-e2e-release-dual-gated`, it stamps the TaskRun with:
  `trusted-pipeline-role: release-authority`
- SPIRE's `konflux-release-authority` ClusterSPIFFEID matches only when **both** conditions are true:
  1. `trusted-pipeline-role == release-authority`
  2. `tekton.dev/pipelineTask == attach-summary-attestations`

Early tasks don't match the second selector, so SPIRE gives them no release identity. Only the final attachment step receives the release SVID to sign into Rekor.

### Model 3: Policy Clearance Tokens (Capability Gating)

Model 3 is an alternative data-plane design that avoids control-plane label matching:
1. `verify-conforma` runs the full policy suite against the image.
2. If it passes, it mints a short-lived **Clearance Token** (JWT) signed by the policy engine, binding the passing verdict to the image digest and PipelineRun UID.
3. The token is passed via an immutable Trusted Artifact OCI archive to `attach-summary-attestations`.
4. The attachment task presents both its SPIFFE identity and the clearance token to Fulcio to obtain a release signing certificate.

---

## Comparison: CI Identity Models

| Capability | Kubernetes SA | GitHub Actions / GitLab CI | Tekton + Kyverno + SPIRE |
| :--- | :--- | :--- | :--- |
| **Trust Anchor** | Cluster API Server | Platform OIDC Issuer | Self-hosted SPIRE Trust Domain |
| **Identity Granularity** | Namespace + ServiceAccount | Repo + Branch / Workflow | **Task Definition + Trust Level + Pod UID** |
| **Admission Checking** | None | SaaS Workflow Validation | **Cosign verification on catalog bundles** |
| **Separation of Duties** | All tasks share identity | Fixed claim structure | **Enforced by Rego policy on SPIFFE URI** |
| **OCI Push Gating** | Static `regcred` secret | Reusable workflows | **Direct OIDC Bearer tokens to registry** |
| **Portability** | Kubernetes only | Locked to SaaS provider | **CNCF Standards (SPIFFE, Sigstore, OCI 1.1)** |

---

## Live Verification & Demo

All five of these use cases are wired together in the repo's live demonstration script:

```bash
# Set up the demo dependencies (Zot OIDC, mock CVE service, SPIRE)
./demo/setup-demo.sh

# Run the interactive 4-act demo
./demo/run-demo.sh
```

For instructions on embedding the terminal into presentation slides via `ttyd` and configuring presenter clicker controls, see the **[KubeCon Demo Guide](../demo/README.md)**.
