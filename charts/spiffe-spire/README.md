# SPIFFE/SPIRE Workload Identity Helm Chart

This Helm chart deploys the SPIRE infrastructure (Server, Agent DaemonSet, SPIFFE CSI Driver, and OIDC Discovery Provider) and configures `ClusterSPIFFEID` custom resources for Tekton workload identity in Konflux.

## ClusterSPIFFEID Resources

1. **`konflux-dev`:**
   - Pod selector: `trusted-task-role: dev`
   - Template: `spiffe://{{ .Values.trustDomain }}/dev/{{ .Values.clusterName }}/{{ .PodSpec.ServiceAccountName }}/{{ index .PodMeta.Labels "tekton.dev/task" }}`
   - Minted for untrusted, inline, or unpinned tasks.

2. **`konflux-trusted-prod`:**
   - Pod selector: `trusted-task-role: prod`
   - Namespace selector: `trusted-tasks-enabled: "true"`
   - Template: `spiffe://{{ .Values.trustDomain }}/trusted/{{ .Values.clusterName }}/{{ .PodSpec.ServiceAccountName }}/{{ index .PodMeta.Labels "tekton.dev/task" }}`
   - Minted for signed catalog tasks verified by Kyverno.

3. **`konflux-release-authority` (Dual-Gated Release Authority):**
   - Pod selector:
     ```yaml
     matchLabels:
       trusted-pipeline-role: release-authority
       tekton.dev/pipelineTask: attach-summary-attestations
     ```
   - Namespace selector: `trusted-tasks-enabled: "true"`
   - Template: `spiffe://{{ .Values.trustDomain }}/release/{{ index .PodMeta.Labels "appstudio.openshift.io/application" }}/{{ index .PodMeta.Labels "tekton.dev/pipeline" }}`
   - Minted **strictly** for the final attestation attachment task in the authorized release pipeline. Early tasks in `managed-tenant` receive NO release authority SVID.

## Fulcio Integration

The chart includes a post-install/post-upgrade Job (`fulcio-spire-integration`) that configures in-cluster Fulcio with the SPIRE OIDC discovery endpoint (`https://spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local`) and SPIRE root CA certificate so that Fulcio can issue X.509 code-signing certificates against SPIRE JWT-SVIDs.
