# Trusted Task Admission Policy — Implementation Status

Date: 2026-05-30

This document records the current implementation state of the admission policy
chart (`charts/admission-policy/`) introduced as the first phase of the
SPIFFE/SPIRE trusted task design
(`docs/plans/2026-05-14-spiffe-spire-trusted-tasks-design.md`).
SPIFFE/SPIRE identity issuance is not yet deployed; this document covers only
the admission classification layer.

## What is deployed

Three Kyverno ClusterPolicies are shipped by `charts/admission-policy/`:

### `classify-taskrun` — trust classification (working)

Stamps every TaskRun with `trusted-task-role: dev` at CREATE/UPDATE time.
When `trustedBundles` are configured, a second rule upgrades matching TaskRuns
to `trusted-task-role: prod` based on two preconditions:

1. The bundle reference is **digest-pinned** (`@sha256:[a-f0-9]{64}`).
2. The bundle URL **matches a configured trusted pattern** (glob converted to
   regex, e.g. `quay.io/konflux-ci/tekton-catalog/*`).

The rule uses chained Kyverno context variables to extract the bundle ref from
both the resolver format (`spec.taskRef.params[?name=='bundle']`) and the
legacy direct format (`spec.taskRef.bundle`).

Verified behaviour:
- Inline taskSpec → `dev`
- Resolver bundle with unpinned tag → `dev`
- Resolver bundle with signed, digest-pinned, pattern-matching ref → `prod`
- Resolver bundle with unsigned, digest-pinned, pattern-matching ref → `prod`
  (**gap — see below**)

### `prevent-pod-label-spoofing` — Pod bypass prevention (working)

Validates (Enforce mode) that any Pod carrying a `trusted-task-role` label has
an ownerReference pointing to a TaskRun. Bare Pods with the label are denied
at admission, preventing direct identity spoofing at the Pod layer.

The check uses a `validate.pattern` (not `validate.deny` + JMESPath) because
Kyverno's JMESPath evaluation of `ownerReferences[?kind == 'TaskRun']` returns
an error when `ownerReferences` is absent, while `pattern` handles nil
gracefully.

### `verify-bundle-signatures` — signature enforcement (partially working)

**Intended** to block admission of TaskRuns that reference a trusted URL
pattern with a digest but no valid cosign signature. The ClusterPolicy exists
and is deployed with correct preconditions (pattern + digest matching), but the
`verifyImages` stanza does **not** enforce signatures in practice.

## Known gap: cosign signature verification for OCI artifacts

Kyverno's `verifyImages` is designed for standard OCI container images, which
carry an OCI image config layer. Tekton bundles are OCI **artifacts** — they
have an OCI manifest but no image config layer. When Kyverno attempts to fetch
and parse the bundle as a container image, it fails with:

```
failed to instantiate handler: failed to extract images: invalid image config
```

This occurs regardless of imageExtractors configuration. The `verifyImages`
code path attempts to parse an OCI image config that does not exist in a Tekton
bundle, making the rule fire but produce an extraction error that Kyverno
silently ignores (because `failurePolicy: Fail` on the ClusterPolicy applies
to webhook-level failures, not rule evaluation errors with `required: true`).

Cosign itself supports OCI artifact signature verification; the limitation is
in Kyverno's image fetching layer.

A secondary issue: the Kyverno 1.17 ClusterPolicy CRD schema does not include
a `filter` field on imageExtractors items. A `filter` field would allow
selecting a single element from an array by key-value match (e.g., extract
only the param where `name == "bundle"` from `spec.taskRef.params`). Without
it, using a wildcard path (`/spec/taskRef/params/*`) extracts all param values,
including non-image values like `"hello"` and `"Task"`, which fail OCI
reference parsing.

## Options for resolving the signature enforcement gap

An investigation of the Kyverno codebase (v1.17.1,
`~/workspace/src/github.com/kyverno/kyverno`) identified the following root
causes and options.

### Root cause analysis

**OCI artifact failure** (`pkg/utils/api/image.go:90`): the `extract()`
function fails when a wildcard (`*`) expansion encounters a plain string value
instead of a map — this is a path resolution error, not a cosign error. A
separate issue is that `pkg/engine/adapters/rclient.go:46` calls
`desc.Image().RawConfigFile()` which returns an empty or non-standard blob for
OCI artifacts, producing garbled image context data. Crucially, the cosign call
itself at `pkg/image/verifiers/cpol/cosign/verifier.go:59` uses
`cosign.VerifyImageSignatures` from `github.com/sigstore/cosign/v3 v3.0.6`,
which is OCI-artifact-agnostic — the cosign library is not the blocker.

**Missing `filter` field** (`api/kyverno/v1/rule_types.go:17`): the
`ImageExtractorConfig` struct has `Path`, `Value`, `Name`, `Key`, `JMESPath`
but no `Filter`. The extraction loop at `pkg/utils/api/image.go:55–86` expands
`*` paths over all array elements with no way to predicate on a sibling field.
`JMESPath` transforms the extracted value string after selection; it cannot
pre-filter which array element to select.

### Option A: Upstream Kyverno — OCI artifact support

Tracked at [kyverno/kyverno#16261](https://github.com/kyverno/kyverno/issues/16261).

Fix `extract()` to skip non-map elements rather than erroring, and skip or
tolerate the `RawConfigFile` fetch in `rclient.go` for OCI artifacts.
**Complexity: moderate.** The extraction skip is trivial (~5 lines); properly
surfacing artifact manifest data in the image context requires more care. Both
changes are architecturally consistent and the cosign path already works.
Recommended to file as a PR — low risk if scoped to the extraction skip.

### Option B: Upstream Kyverno — `filter` field in imageExtractors

Tracked at [kyverno/kyverno#16260](https://github.com/kyverno/kyverno/issues/16260).

Add a `Filter` field to `ImageExtractorConfig`, pass it through
`lookupImageExtractor()`, and evaluate it in the `*` expansion block of
`extract()` using the existing JMESPath engine. **Complexity: moderate** —
~10 lines of logic, but CRD schema regeneration and webhook validation are the
fiddly parts. Additive, no breaking change. Worth filing as a feature request;
the use case (structured params arrays with a discriminator field) is generic,
not Tekton-specific. Note: this alone does not fix the OCI artifact issue.

### Option C: Custom ValidatingWebhook

A small Go service using `github.com/sigstore/cosign/v3` verifies OCI artifact
signatures for bundle refs extracted from `spec.taskRef.params`. The webhook
receives `AdmissionReview` requests, extracts the bundle param, and calls
`cosign.VerifyImageSignatures`. This is the only option that fully works today
without upstream changes.

### Option D: Registry access control

Enforce signing at push time via registry policy or CI gate. If the trusted
bundle registry only accepts pushes from a signing pipeline, unsigned bundles
cannot appear there regardless of admission policy. Combined with the URL
pattern + digest check in `classify-taskrun`, this provides equivalent
assurance without in-cluster verification.

## Current security properties

With the admission policy chart deployed but signature enforcement not working:

| Scenario | Admitted? | Label |
|---|---|---|
| Inline taskSpec | Yes | `dev` |
| Bundle: untrusted URL | Yes | `dev` |
| Bundle: trusted URL, unpinned tag | Yes | `dev` |
| Bundle: trusted URL, digest-pinned, signed | Yes | `prod` |
| Bundle: trusted URL, digest-pinned, **unsigned** | Yes | `prod` (**gap**) |
| Bare Pod with `trusted-task-role` | **No** | — |

The gap means registry access control is the primary enforcement mechanism for
the unsigned-but-trusted-pattern case. Once SPIFFE/SPIRE is deployed, the
`prod` SPIFFE identity will still be issued for unsigned bundles that happen to
match a trusted URL pattern with a pinned digest.

## Remaining work

1. **Resolve signature enforcement** — via upstream Kyverno contribution or
   custom webhook (see options above).
2. **Deploy `charts/spiffe-spire/`** — SPIRE server, agent, CSI driver, OIDC
   discovery provider, ClusterSPIFFEID resources, and Fulcio integration.
3. **Task bundle modifications** — add SPIFFE Workload API CSI volume to
   `verify-conforma` and `attach-vsa` tasks so they sign attestations with
   their SPIFFE-derived Fulcio certificate.
