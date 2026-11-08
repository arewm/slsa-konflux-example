# Guide: Vault Token Exchange for Legacy Services (Pattern 2 Extension)

This guide covers the **legacy-service variant of Pattern 2 (Portable Secretless
Service Access)**: a task exchanges its SPIRE-issued JWT-SVID for a **static
credential** via HashiCorp Vault. Use it for services that cannot validate OIDC
tokens themselves — for example, content repositories behind static API tokens.

---

## 1. Problem Statement

Pattern 2's secretless access works when the target service validates JWTs directly
against SPIRE's JWKS endpoint (like the demo's Zot registry and CVE database). But many
real services predate OIDC entirely and only accept static credentials. The naive
fallback — mounting the static token into every pipeline pod — reintroduces exactly the
ambient-secret flaw from Act 1 of the demonstration: any compromised step in the
namespace can read it.

## 2. Architecture

The broker pattern: Vault holds the static credential and trusts SPIRE's OIDC discovery
endpoint, so the credential's release is bound to a specific SPIFFE ID — that is, to an
admission-verified task role.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 1. Admission (existing machinery)                                           │
│    Scanner task runs from a digest-pinned, signed catalog bundle            │
│    → Kyverno classifies trusted-task-role: prod                             │
│    → SPIRE mints spiffe://…/trusted/kind-konflux/default/trivy-sbom-scan    │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 2. Token exchange                                                           │
│    Task fetches a JWT-SVID (audience: vault) from the SPIRE Workload API    │
│    POST /v1/auth/jwt/login {"role":"scanner","jwt":"<svid>"}                │
│    Vault validates the JWT against SPIRE's OIDC discovery endpoint +        │
│    bound_subject == the scanner SPIFFE ID                                   │
│    → Vault issues a short-TTL token with policy cve-feed-reader             │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 3. Credential use                                                          │
│    GET /v1/secret/data/legacy-api with the Vault token                     │
│    → the static credential is released only to the verified scanner role    │
│    → the legacy service is untouched; no long-lived secret sits in the pod  │
└─────────────────────────────────────────────────────────────────────────────┘
```

The pod holds **no pre-shared secret**. The credential materializes per-run, inside
the one task authorized to have it, and every exchange is auditable at the broker.

## 3. Implementation

Vault runs in **dev mode**: in-memory storage, no unseal step, plain HTTP
inside the cluster. That is deliberate for a KinD exploration cluster and
changes nothing about what the demo shows — the JWT-auth binding to
SPIFFE IDs is identical in dev and production mode. Adapting the chart for
production means: serve TLS with an in-cluster certificate, switch to
integrated raft storage so secrets survive restarts, and set up an unseal
strategy (Kubernetes auth-based auto-unseal or a documented manual flow).

| Component | Location |
| :--- | :--- |
| Vault (dev mode) + SPIRE-backed JWT auth | `charts/vault-legacy-exchange/` |
| Vault role `scanner` (bound_subject = scanner SPIFFE ID) | chart config job |
| KV secret + read-only policy `cve-feed-reader` | chart config job |
| Audience-parameterized scanner task variant | `demo/manifests/trivy-sbom-scan-vault.yaml` |
| Standalone demo script | `demo/vault-exchange-demo.sh` |

The catalog `trivy-sbom-scan` task hardcodes its JWT audience, so the demo pushes a
variant of the same task with a parameterized `jwt-audience`, signed with the demo
catalog key. Admission classifies it `prod`, which is what earns the trusted SPIFFE ID.

The Vault deployment in `charts/vault-legacy-exchange/` runs in dev mode. Do not use
it as-is in production.

## 4. Running the Demo

```bash
./demo/vault-exchange-demo.sh            # deploy + positive + negative cases
./demo/vault-exchange-demo.sh --clean    # remove demo resources
```

The script verifies:

1. **POSITIVE** — the trusted scanner task obtains a JWT-SVID (aud `vault`), logs in to
   Vault, and reads `secret/legacy-api`.
2. **NEGATIVE** — an inline (dev-tier) task attempts the same login and is **denied**:
   its JWT subject (`spiffe://…/dev/…`) does not match the role's `bound_subject`.

## 5. Relation to the Release Boundary Design

The same Vault machinery is the foundation for the **policy-gated release signing**
design (see "Label Guard Hardening" in the [Dual-Gated Release Guide](dual-gated-release.md)): a run-scoped
capability written on policy PASS and readable only by the same-run signer. This demo
covers the simpler, single-input form (identity → credential); the release-signing
variant adds run and digest scoping.
