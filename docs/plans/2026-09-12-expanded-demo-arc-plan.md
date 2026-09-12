# Plan: KubeCon NA 2026 Expanded Demo Arc — Secretless Tasks, Gated OCI Push, & Dual-Gated Release Authority

**Date:** 2026-09-12  
**Target Event:** KubeCon NA 2026 ("Your CI's Mistaken Identity")  
**Target Branch:** `worktree-spiffe-spire-exploration` (in `.claude/worktrees/spiffe-spire-exploration/`)  
**Context:** Local Kind cluster (`konflux`), Konflux v0.2.2, Patched Kyverno (branch `fix/imageextractor-filter`), SPIFFE/SPIRE with OIDC discovery provider.

---

## 1. Executive Summary & The Expanded Three-Act Demo Arc

The current demo validates **separation of duties for Sigstore signing** (Trivy scanner vs Buildah builder) and **dual-gated release authority**. However, audience members inevitably ask:
> *"Is workload identity only good for Sigstore signing? How does this eliminate static secrets and ambient authority across the rest of our pipelines?"*

This plan outlines the architecture, setup, and execution steps for an expanded, 3-part live demonstration arc:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ DEMO 1: The Ambient Push Hijack vs Task-Scoped OCI Push Gating                         │
│   • Baseline: Traditional ServiceAccount/namespace auth allows rogue task to overwrite │
│               production image tag with "malicious" payload.                           │
│   • Hardened: Zot OIDC Bearer auth restricts push permissions ONLY to the task with    │
│               the vetted builder SPIFFE identity. Attacker receives 401 Unauthorized. │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ DEMO 2: Portable Secretless Service Access (Cross-Namespace Token Exchange)             │
│   • Problem: Tasks traditionally mount Kubernetes Secrets containing static API tokens │
│              to talk to internal services (CVE db, vault, scanners).                   │
│   • Solution: Trusted task connects to SPIFFE CSI socket, mints JWT-SVID for audience  │
│               https://internal-service.local, and authenticates via OIDC federation.   │
│   • Contrast: Dev/untrusted task presents unapproved role and is denied access.        │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ DEMO 3: Dual-Gated Managed Release Authority & Cryptographic Capability Gating         │
│   • Baseline: Release ServiceAccount has ambient authority to push & sign prematurely.│
│   • Hardened: Dual-Gating ensures early tasks have ZERO signing identity; only the     │
│               post-verification attachment task receives release authority SVID.       │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Technical Findings & Prerequisites

### A. Upstream Multi-Arch Zot Image
- **Image:** `ghcr.io/project-zot/zot:latest` (or `ghcr.io/project-zot/zot:v2.1.21`)
- **Architectures:** Multi-arch manifest index supporting `linux/arm64` (v8) and `linux/amd64` (as well as FreeBSD).
- **Binary Capabilities:** Unlike `quay.io/konflux-ci/zot` (which is `zot-minimal` and lacks OIDC), the upstream `ghcr.io/project-zot/zot` includes the full extension set (`-events-imagetrust-lint-metrics-mgmt-profile-scrub-search-sync-ui-userprefs`).
- **OIDC Workload Identity Verification:** Tested and confirmed working with SPIRE's OIDC Discovery Provider (`https://spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local`) when SPIRE's root CA is provided in `certificateAuthority`.
- **Entrypoint:** `/usr/local/bin/zot-linux-arm64` (or `zot-linux-amd64`), called as `serve /etc/zot/config.json`.

### B. Handling Basic Auth Coexistence with OIDC Bearer in Zot
- **Finding:** In Zot, when `http.auth.bearer` is active, the `/v2/` API expects Bearer authentication. Sending standard `Authorization: Basic ...` headers to `/v2/` can fail if basic auth is not configured alongside an access control bypass.
- **Solution Options:**
  1. **Dual Configuration in Zot:** Configure Zot `accessControl` policies so that repositories matching `slsa-e2e-test` allow basic credentials (`konflux`), while `released-test-app` strictly requires OIDC bearer identity.
  2. **Dedicated Registry Endpoint / Ingress Port:** Map host port `5001` or an internal port specifically for OIDC bearer evaluation.

---

## 3. Detailed Demo Specifications

### Demo 1: Ambient Push Hijack vs. Task-Scoped OCI Push Gating

#### The Narrative:
In a typical pipeline, a developer configures `regcred` on the pipeline's ServiceAccount so the builder task can push images. However, an attacker injects a malicious task (or a compromised dependency-fetch step runs after the build) that uses the ambient ServiceAccount secret to overwrite the image tag with a backdoored image.

#### 1. The Attack (Traditional ServiceAccount Ambient Secret):
1. **Normal Build Task:**
   Pushes a legitimate image to `registry-service.kind-registry/slsa-e2e-test:latest`:
   ```bash
   # Pod runs:
   echo "echo 'Hello from legitimate build!'" | podman/buildah build -t registry-service.kind-registry/slsa-e2e-test:latest
   podman push registry-service.kind-registry/slsa-e2e-test:latest
   ```
   *Verification:* Running the image outputs `"Hello from legitimate build!"`.
2. **Malicious TaskRun (Ambient Credential Abuse):**
   A rogue/untrusted TaskRun running under the same ServiceAccount (e.g. `default` in `default-tenant`) uses the ambient `regcred-internal-registry`:
   ```bash
   echo "echo 'MALICIOUS BACKDOOR EXECUTED'" | podman/buildah build -t registry-service.kind-registry/slsa-e2e-test:latest
   podman push registry-service.kind-registry/slsa-e2e-test:latest
   ```
   *Result:* Because the ServiceAccount owns the credential, the registry accepts the overwrite. The backdoored image is now live!

#### 2. The Defense (Task-Scoped SPIFFE OIDC Bearer Gating):
1. Configure Zot's access control policy:
   ```json
   "accessControl": {
     "repositories": {
       "slsa-e2e-test": {
         "policies": [
           {
             "users": ["spiffe://konflux-ci.dev/trusted/kind-konflux/default/buildah-oci-ta"],
             "actions": ["read", "create", "update"]
           }
         ]
       }
     }
   }
   ```
2. **Legitimate Builder Task:**
   Presents its Kyverno-admitted, SPIRE-minted JWT:
   `sub: spiffe://konflux-ci.dev/trusted/kind-konflux/default/buildah-oci-ta`
   Zot authorizes the push: **`201 Created` / `200 OK`**.
3. **Malicious / Compromised Task:**
   Even if it runs in the same namespace under the same Kubernetes ServiceAccount, Kyverno labels it `dev`, and SPIRE mints:
   `sub: spiffe://konflux-ci.dev/dev/kind-konflux/default/rogue-task`
   The rogue task attempts to push to `slsa-e2e-test`:
   Zot evaluates the claim against the access policy and rejects the push: **`403 Forbidden` / `401 Unauthorized`**.

---

### Demo 2: Portable Secretless Service Access (Cross-Namespace Token Exchange)

#### The Narrative:
Pipelines frequently need to communicate with external APIs—an internal enterprise vulnerability database, an artifact metadata store, or a secret vault. Developers usually copy API tokens into Kubernetes Secrets across every tenant namespace.

#### 1. Architecture:
- Deploy a lightweight service `cve-database-service` in a dedicated namespace `services`.
- The service publishes no static shared passwords and requires no Kubernetes Secrets in `default-tenant`.
- It validates callers using OpenID Connect against SPIRE:
  - JWKS endpoint: `https://spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local/keys`
  - Expected audience: `https://cve-database.internal`

#### 2. The Demonstration:
1. **Trusted Scanner Task (`trivy-sbom-scan`):**
   - Connects to `/spiffe-workload-api/spire-agent.sock`.
   - Requests a JWT-SVID for audience `https://cve-database.internal`.
   - Calls the service:
     ```bash
     curl -s -H "Authorization: Bearer ${JWT_SVID}" https://cve-database.services.svc/api/v1/vulnerabilities
     ```
   - **Service Log Output:**
     ```text
     [AUTH] Validating incoming token against SPIRE OIDC Discovery...
     [AUTH] Verified token for subject: spiffe://konflux-ci.dev/trusted/kind-konflux/default/trivy-sbom-scan
     [AUTHZ] Role 'trivy-sbom-scan' is authorized to query vulnerability feed.
     HTTP/1.1 200 OK - Feed returned (zero static secrets used).
     ```
2. **Untrusted / Inline Task:**
   - Attempts to access the same service.
   - Presents token with `sub: spiffe://konflux-ci.dev/dev/kind-konflux/default/arbitrary-task`.
   - **Service Log Output:**
     ```text
     [AUTH] Validating incoming token against SPIRE OIDC Discovery...
     [AUTH] Verified token for subject: spiffe://konflux-ci.dev/dev/...
     [AUTHZ] Role 'dev' is unauthorized to query vulnerability feed!
     HTTP/1.1 403 Forbidden: Caller lacks scanner authorization.
     ```

---

### Demo 3: Dual-Gated Managed Release Authority (Model 2)

*(Already implemented and verified live in the cluster; codified in `managed-context/pipelines/slsa-e2e-release-dual-gated/slsa-e2e-release-dual-gated.yaml` and `docs/dual-gated-release-guide.md`)*.

#### The Narrative:
In the platform's release namespace (`managed-tenant`), releasing an artifact requires two distinct gates:
1. **Early Tasks Denied Identity:** Tasks like `collect-data` or `apply-mapping` cannot sign or claim release authority.
2. **Policy Verification Gate:** `verify-conforma` must evaluate 104 rules and pass with 0 violations.
3. **Dual-Gated Conjunction:** Only `attach-summary-attestations` running inside the authorized release pipeline receives:
   `spiffe://konflux-ci.dev/release/test-app/slsa-e2e-release-dual-gated`.
4. Keyless Cosign signs the VSA and SVR directly into Rekor.

---

## 4. Worktree Layout & Existing Implementation Map

For any agent or engineer continuing this implementation, the current assets on branch `worktree-spiffe-spire-exploration` are:

```
.claude/worktrees/spiffe-spire-exploration/
├── charts/
│   ├── admission-policy/          # Kyverno policies
│   │   ├── README.md
│   │   └── templates/
│   │       ├── classify-taskrun.yaml          # Sets dev vs prod label
│   │       ├── prevent-pod-label-spoofing.yaml# Blocks tenant self-labeling
│   │       ├── verify-bundle-signatures.yaml  # Pinned catalog Cosign check
│   │       └── classify-release-authority.yaml# Managed release pipeline role
│   └── spiffe-spire/              # SPIFFE/SPIRE deployment
│       ├── README.md
│       └── templates/
│           ├── cluster-spiffe-id-dev.yaml     # Dev SVID (excludes managed-tenant)
│           ├── cluster-spiffe-id-prod.yaml    # Prod task SVID
│           ├── cluster-spiffe-id-release-authority.yaml # Dual-gated release SVID
│           └── fulcio-integration-job.yaml    # Fulcio OIDC trust config
├── demo/
│   ├── demo-magic.sh              # Terminal simulation engine
│   └── run-demo.sh                # Interactive 4-scene live stage runner
├── docs/
│   ├── dual-gated-release-guide.md# Model 2 walkthrough & inspection guide
│   └── plans/
│       ├── 2026-05-14-spiffe-spire-trusted-tasks-design.md
│       ├── 2026-05-30-trusted-task-admission-status.md
│       └── 2026-09-11-task-identity-and-release-gating-plan.md # Model 3 spec
├── managed-context/
│   ├── pipelines/
│   │   └── slsa-e2e-release-dual-gated/       # Working Model 2 release pipeline
│   └── tasks/
│       ├── attach-summary-attestations/       # Dual-mode keyless Cosign task
│       └── verify-conforma/                   # Pinned Conforma verification task
└── scripts/
    └── setup-prerequisites.sh     # Automates Chains sigstore-bundle & registry
```

---

## 5. Step-by-Step Implementation Checklist for the Next Session

- [ ] **Step 1: Deploy Upstream Multi-Arch Zot Container (`ghcr.io/project-zot/zot:v2.1.21`)**
  - Update deployment `registry` in `kind-registry` to use `ghcr.io/project-zot/zot:v2.1.21` with command `["/usr/local/bin/zot-linux-arm64", "serve", "/etc/zot/config.json"]` (or architecture-appropriate binary).
  - Mount `trusted-ca` bundle so Zot trusts SPIRE's OIDC discovery endpoint TLS.
- [ ] **Step 2: Wire Demo 1 (Malicious Push vs Trusted Push)**
  - Create `demo-push-legitimate.yaml` (TaskRun with `trusted-task-role: prod` pushing benign image).
  - Create `demo-push-malicious.yaml` (TaskRun attempting to push backdoored image).
  - Show live terminal verification: legitimate push succeeds; malicious push receives 401/403.
- [ ] **Step 3: Wire Demo 2 (Secretless Service Token Exchange)**
  - Deploy simple mock verification service `cve-service` in namespace `services`.
  - Execute scanner task showing JWT-SVID presentation and successful 200 OK.
  - Execute dev task showing rejection and 403 Forbidden.
- [ ] **Step 4: Update `demo/run-demo.sh`**
  - Incorporate the new scenes into the interactive demo-magic script.
- [ ] **Step 5: Commit with `write-commit-message` Skill**
  - Ensure all commits use the Luna subagent with `Assisted-by: goose (gemini-3.8-flash)`.
