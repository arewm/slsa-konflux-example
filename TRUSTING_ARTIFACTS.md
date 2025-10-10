# Trusting Artifacts

Tekton Chains uses [type hinting](https://tekton.dev/docs/chains/slsa-provenance/#type-hinting) on PipelineRuns and TaskRuns to determine what to sign and generate provenance for.
While we like Chains's observer pattern, we recognize that it can just as easily generate provenance for malicious artifacts
as it can for legitimate ones.