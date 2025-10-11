# Trusting Artifacts

Tekton Chains uses [type hinting](https://tekton.dev/docs/chains/slsa-provenance/#type-hinting) on PipelineRuns and TaskRuns to determine what to sign and generate provenance for.
While Chains's observer pattern is powerful as it ensures that we have a separation of the signing material, Chains can just as easily generate provenance for malicious artifacts
as it can for legitimate ones. Therefore, 