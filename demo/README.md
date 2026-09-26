# KubeCon NA 2026: "Your CI's Mistaken Identity"

> **Live Demonstration Arc:** Secretless Tasks, Task-Scoped OCI Push Gating, Cross-Namespace Token Exchange, and Dual-Gated Managed Release Authority.

---

## Overview

Modern cloud-native CI systems frequently suffer from **mistaken identity**:
1. **Ambient Authority**: Every task in a Kubernetes namespace runs under a shared `ServiceAccount` and mounts ambient secrets (`regcred`, API tokens). Any compromised step or rogue developer task can hijack these credentials to overwrite production tags or exfiltrate secrets.
2. **Coarse-Grained Attestation**: Standard keyless signing tokens identify only the namespace or service account (`sub: system:serviceaccount:<ns>:<sa>`), failing to distinguish a build task from a vulnerability scanner.
3. **Overprivileged Release Pipelines**: Release authorities that sign SLSA provenance and Verification Summary Attestations (VSAs) often inherit ambient credentials across an entire namespace.

This demonstration proves an end-to-end defense across the entire software supply chain lifecycle:
- **Admission Verification**: Kyverno inspects TaskRuns before scheduling, verifying Sigstore signatures on pinned catalog bundles and assigning role labels (`dev` vs. `prod`).
- **Cryptographic Workload Identity**: SPIRE issues short-lived, task-scoped SPIFFE SVIDs (X.509 and JWT) based on Kyverno-validated pod labels and precise pod UIDs.
- **Separation of Duties**: Conforma / Enterprise Contract (OPA Rego) policies ensure that scanners can only sign vulnerability reports and builders can only sign provenance.
- **Task-Scoped OCI Push Gating**: Zot OCI registry validates bearer JWT tokens directly against SPIRE's OIDC discovery endpoint, restricting image pushes to vetted builder roles.
- **Portable Secretless Service Access**: Pipelines authenticate to internal services (e.g. CVE feeds) using short-lived audience-scoped JWT-SVIDs without static Kubernetes secrets.
- **Managed Release Boundary (Model 2 Dual-Gating)**: Managed release signing requires both PipelineRun-level classification and task-level pod selectors, generating keyless attestations signed via SPIFFE identity and recorded in Rekor.

---

## Directory Structure

```text
demo/
├── README.md                      # This guide
├── setup-demo.sh                  # Pre-flight setup: syncs Rekor/TUF, deploys OIDC Zot, CVE service, and demo-app
├── serve-slides.sh                # Multi-port ttyd web terminal launcher for slide embeds (ports 7680-7684)
├── run-demo.sh                    # Interactive live demonstration script (Acts 0 through 4)
├── cleanup-demo.sh                # Synchronous, idempotent cleanup script
├── demo-magic.sh                  # Terminal presentation helper (simulated typing & clicker support)
└── manifests/
    ├── snapshot.yaml              # AppStudio Snapshot manifest for demo-app releases
    ├── zot-oidc.yaml              # OIDC-authenticated Zot registry deployment & access policy
    ├── cve-database-service.yaml  # Secretless mock CVE database service (OIDC JWT validator)
    ├── separation_of_duties.rego  # Conforma Rego policy enforcing role-scoped attestations
    └── separation_of_duties_test.rego # Rego unit test suite (verifies builder forgery rejection)
```

---

## Prerequisites

Before running the demo, ensure the following tooling and infrastructure are available:

1. **Active KinD Cluster with Konflux & SPIRE**:
   - Cluster created with KinD on Podman/Docker.
   - Konflux operator installed with `default-tenant` and `managed-tenant` namespaces.
   - SPIRE Server, Agent, CSI Driver, and OIDC Discovery Provider deployed in `spire`.
   - Sigstore stack (Fulcio, Rekor, TUF) running.
   - Kyverno admission controller active with policies deployed from `charts/admission-policy/`.
2. **Local CLI Tools**:
   - `kubectl` (configured to point to the KinD cluster)
   - `helm` (v3+)
   - `yq` (v4+)
   - `jq` (v1.6+)
   - `opa` (Open Policy Agent CLI)
   - `curl`, `openssl`, and `python3`
3. **Port Forwarding / Endpoints**:
   - Konflux UI: `https://localhost:9443`
   - Zot OCI Registry: `https://localhost:5001` (NodePort)

---

## Setup & Pre-Flight

Run the setup script to initialize the environment:

```bash
./demo/setup-demo.sh
```

### What `setup-demo.sh` Does:
1. **Verifies Prerequisites**: Checks connectivity and ensures all required namespaces exist.
2. **Synchronizes Rekor / TUF Keys**: Automatically aligns the active Rekor public key with the local TUF root secret (`rekor-public-key` in `tuf-system`) if the cluster was restarted.
3. **Deploys OIDC Zot Registry**: Applies `demo/manifests/zot-oidc.yaml` and waits for rollout.
4. **Deploys CVE Mock Service**: Applies `demo/manifests/cve-database-service.yaml` and waits for rollout.
5. **Onboards `demo-app`**: Installs `demo-app` into `default-tenant` using the `charts/component-onboarding` Helm chart and applies `demo/manifests/snapshot.yaml`.
6. **Establishes Clean Baseline**: Executes `demo/cleanup-demo.sh` to ensure no lingering runs or rogue tags exist.

---

## Running the Demonstration

### 1. Interactive Mode (For Presentations)

Run the script directly in your terminal:

```bash
./demo/run-demo.sh
```

- Simulates realistic command typing.
- Pauses before each command. Press **`[ENTER]`** to proceed.
- Clears the terminal between acts to maintain audience focus.

### 2. Fast / CI Mode (No Typing Delays or Pauses)

To execute all acts non-interactively without delays:

```bash
./demo/run-demo.sh -n -d
```
*(or via environment variables: `NO_WAIT=true ./demo/run-demo.sh`)*

### 3. Immediate Auto-Cleanup

By default, demo resources are retained so they can be inspected in the Konflux UI. To automatically clean up upon completion:

```bash
DEMO_CLEANUP=true ./demo/run-demo.sh
```

---

## Slide Integration & Presentation Mode

This demo includes a multi-port slide server (`demo/serve-slides.sh`) designed for embedding live web terminals directly into browser-based slides (like **Remark.js**, **Slidev**, or **Reveal.js**) via `ttyd`:

### 1. Predefined Act Ports

| Port | Demo Target | Slide Section |
|------|-------------|---------------|
| **7681** | **Act 1** | Kyverno at the Gate & Separation of Duties |
| **7682** | **Act 2** | Ambient Push Hijack vs. Task-Scoped OCI Push Gating |
| **7683** | **Act 3** | Portable Secretless Service Access (CVE Database) |
| **7684** | **Act 4** | Managed Release Boundary (Dual-Gated Authority) |
| **7680** | **Full Arc** | Complete End-to-End Walkthrough (Acts 0 through 4) |

### 2. Managing Slide Terminals

To launch background `ttyd` servers on all ports before presenting:

```bash
./demo/serve-slides.sh start
```

Check port status at any time:

```bash
./demo/serve-slides.sh status
```

Stop all background instances:

```bash
./demo/serve-slides.sh stop
```

### 3. Progressive Enhancement in Slides

When embedding in slides, use a dynamic check so viewers without a local cluster see a fallback card with a link to the demo guide:

```html
<div class="demo-slide-container" data-port="7681">
  <!-- Fallback card when presenting offline or viewing slides on GitHub Pages -->
  <div class="demo-offline-fallback">
    <h4>🖥️ Live Demo: Act 1</h4>
    <p>Kyverno Admission & Separation of Duties</p>
    <code>./demo/run-demo.sh --act 1</code>
  </div>

  <!-- Injected dynamically if ttyd is listening -->
  <div class="demo-terminal-frame" style="display: none;"></div>
</div>

<script>
fetch("http://localhost:7681", { mode: "no-cors" })
  .then(() => {
    const container = document.querySelector('[data-port="7681"]');
    container.querySelector(".demo-offline-fallback").style.display = "none";
    const term = container.querySelector(".demo-terminal-frame");
    term.style.display = "block";
    term.innerHTML = '<iframe src="http://localhost:7681" style="width:100%;height:450px;border:none;"></iframe>';
  })
  .catch(() => {});
</script>
```

### 4. Seamless Presenter Clicker Flow & Focus Recovery

- **Clicker Keys Supported in Demos**: While a demo act is running, `demo/demo-magic.sh` listens for `[Enter]`, `[Space]`, `[Right Arrow]`, and `[PageDown]` (the standard hardware key sent by presentation remotes).
- **Session Preservation**: When an act finishes, the process stays open in an interactive shell so the WebSocket connection never drops.
- **Escape Key Interception (`[Esc]`)**: Cross-origin iframes normally trap keyboard focus. `demo/serve-slides.sh` generates a slide-aware terminal index that intercepts `[Escape]` in the DOM capture phase, blurs the terminal, and posts `postMessage({ type: 'DEMO_ESCAPE' }, '*')` to the slide window, immediately returning focus to Remark.js.
- **Act Completion Auto-Defocus**: On act completion, `run-demo.sh` outputs OSC escape sequence `\033]0;ACT_<N>_COMPLETE\007`. The terminal index observes this title mutation and automatically sends `DEMO_ACT_COMPLETE` to blur the terminal and return focus to the slide deck—allowing the very next clicker press to advance the slides.
- **Visual Focus Indicator**: The terminal toolbar dynamically displays a green `SLIDES ACTIVE` status badge confirming keyboard control is restored to presentation navigation.

---

## Walkthrough of the Acts

### Act 0: Pre-Flight Verification & Idempotent Baseline
- Verifies Kyverno admission policies (`classify-taskrun`, `verify-bundle-signatures` [ImageValidatingPolicy], `prevent-pod-label-spoofing`, `classify-release-authority`).
- Confirms SPIRE pods and OIDC discovery endpoints are healthy.
- Displays clickable browser links to monitor the application in the Konflux UI (`https://localhost:9443`).

### Act 1: Kyverno at the Gate & Separation of Duties Attestations
1. **Untrusted Inline Task**: Submits a TaskRun with inline scripting. Kyverno admits it but stamps `trusted-task-role: dev`. SPIRE mints an unprivileged identity (`spiffe://konflux-ci.dev/dev/.../task`).
2. **Attacker Spoof Attempt**: An adversary submits an unsigned task claiming the trusted catalog namespace (`registry-service.kind-registry/tekton-catalog/demo-unsigned-task`). Kyverno's `verify-bundle-signatures` blocks admission at the API boundary via Sigstore image verification.
3. **Cryptographically Signed Catalog Task**: Submits a Cosign-signed task bundle. Kyverno verifies the signature and promotes the label to `trusted-task-role: prod`. SPIRE mints a vetted production identity.
4. **Separation of Duties (OPA Rego)**: Runs unit tests against `separation_of_duties.rego`, proving that a builder task attempting to sign a clean CVE scan is denied by policy.

### Act 2: Ambient Push Hijack vs. Task-Scoped OCI Push Gating
1. **The Ambient Authority Flaw**: Inspects standard Kubernetes `ServiceAccount` projected tokens (`system:serviceaccount:default-tenant:default`). Demonstrates that any pod sharing the service account can hijack `regcred` to overwrite `slsa-e2e-test:latest` with a backdoor text payload.
2. **Task-Scoped OCI Push Gating**: Shows Zot configured with OIDC bearer authentication.
   - **Rogue Task Attempt**: A dev task presents its SPIFFE JWT-SVID (`spiffe://konflux-ci.dev/dev/.../rogue-attacker-task`). Zot rejects the upload handshake with **HTTP/2 403 Forbidden**.
   - **Legitimate Builder Task**: The vetted builder bundle (`buildah-oci-ta`) presents its identity (`spiffe://konflux-ci.dev/trusted/.../buildah-oci-ta`). Zot accepts the upload session with **HTTP/2 202 Accepted**.

### Act 3: Portable Secretless Service Access (Cross-Namespace Token Exchange)
1. **Secretless Microservice**: Queries the internal CVE database service in `services`. The service mounts zero Kubernetes secrets and validates callers via SPIRE's `/keys` JWKS endpoint.
2. **Untrusted Caller**: An arbitrary task requests an audience-scoped JWT for `https://cve-database.internal`. The service validates the signature but returns **HTTP/1.0 403 Forbidden** due to role authorization failure.
3. **Vetted Scanner (`trivy-sbom-scan`)**: The scanner task requests a JWT and queries the feed. The service validates the caller role and returns **HTTP/1.0 200 OK** with vulnerability data.

### Act 4: Managed Release Boundary (Dual-Gated Authority)
1. **Release Custom Resource**: Creates an AppStudio `Release` resource in `default-tenant` referencing `demo-app-release-plan` and `demo-app-snapshot`.
2. **Dual-Gated PipelineRun**: Executes `demo-dual-gated-release-...` in `managed-tenant`.
   - Kyverno mutates the TaskRun with `trusted-pipeline-role: release-authority`.
   - SPIRE enforces that only `attach-summary-attestations` within this pipeline receives the release authority SVID (`spiffe://konflux-ci.dev/release/demo-app/slsa-e2e-release-dual-gated`).
   - The task executes keyless `cosign attest` using the local Fulcio and Rekor instances.
3. **OCI 1.1 Referrers & Rekor Transparency Log**:
   - Queries Zot for OCI 1.1 referrers attached to the release digest (`application/vnd.dev.sigstore.bundle.v0.3+json`).
   - Executes a dynamic query job against Rekor, extracts the latest log entry, and parses the X.509 certificate SAN to verify the exact SPIFFE Release Authority identity.

---

## Observing in the Konflux UI

Open **`https://localhost:9443`** in your browser (accept the self-signed TLS certificate) and log in as:
- **Username**: `user1@konflux.dev`
- **Password**: `password`

Direct links:
- **Application Overview**: [`https://localhost:9443/application-pipeline/workspaces/default/applications/demo-app`](https://localhost:9443/application-pipeline/workspaces/default/applications/demo-app)
- **Releases View**: [`https://localhost:9443/application-pipeline/workspaces/default/applications/demo-app/releases`](https://localhost:9443/application-pipeline/workspaces/default/applications/demo-app/releases)
- **PipelineRuns Activity**: [`https://localhost:9443/application-pipeline/workspaces/default/applications/demo-app/activity/pipelineruns`](https://localhost:9443/application-pipeline/workspaces/default/applications/demo-app/activity/pipelineruns)

---

## Cleanup & Repeatability

The demo is designed to be **strictly idempotent** and can be run repeatedly back-to-back without manual cluster re-initialization.

### Execution Artifact Cleanup (Default)
To delete all TaskRuns, Pods, Releases, PipelineRuns, and Rekor query jobs while keeping `demo-app` and services installed:

```bash
./demo/cleanup-demo.sh
```

*Note: This automatically restores `slsa-e2e-test:latest` to its pristine payload.*

### Full Infrastructure Purge
To completely uninstall `demo-app`, the mock CVE service, and the OIDC Zot deployment:

```bash
./demo/cleanup-demo.sh --all
```

---

## Troubleshooting & Key Invariants

1. **Rekor Transparency Log Key Mismatches**:
   - In local KinD environments, Rekor server keys are ephemeral across cluster restarts.
   - If Cosign fails with `not enough verified log entries from transparency log`, run `./demo/setup-demo.sh`, which automatically detects key drift, updates `secret/rekor-public-key` in `tuf-system`, and restarts the TUF server.
2. **Container Image Distroless Invocations**:
   - `ghcr.io/spiffe/spire-agent` is a scratch/distroless image. Do not attempt to invoke `/bin/sh` inside it; invoke `/opt/spire/bin/spire-agent` directly.
3. **SPIRE Agent Sync Timing**:
   - Tasks mounting the SPIFFE Workload API CSI driver must allow 8–10 seconds for the node agent to register the pod UID with `spire-server` before requesting SVIDs.
