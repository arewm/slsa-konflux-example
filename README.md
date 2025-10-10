# SLSA End-to-End Example (Konflux style)

This repository demonstrates how to achieve end-to-end SLSA (Supply-chain Levels for Software Artifacts) compliance using [Konflux](https://konflux-ci.dev).
It is created in response to the SLSA [request for examples](https://slsa.dev/blog/2025/07/slsa-e2e).

If you are not familiar with Konflux, it is an open source, cloud-native software factory focused on software supply chain security. We understand that there
are often competing interests between software developers and security professionals, but we try to strike a balance. By hardening our platform so that we can
achieve SLSA Build L3 out of the box, we give developers the flexibility to build what they need to while also ensuring that the necessary requirements are
met before those artifacts are pushed anywhere outside their control.

After you complete the prerequisites, this repository provides a self-contained example for how to configure a Konflux tenant, onboard a component, and release
it while ensuring that we meet all required policies. We will show you along the way how we leverage guidance from many of SLSA's tracks.

## Table of contents



## Pre-requisites

Before being able to explore SLSA with Konflux, you will need to have a running instance of it. We have [instructions](https://github.com/konflux-ci/konflux-ci?tab=readme-ov-file#trying-out-konflux). While these instructions describe the process for building artifacts, we will also do that here. So you can stop after you complete the following:
- [Installing Software Dependencies](lux-ci?tab=readme-ov-file#installing-software-dependencies)
- [Bootstrapping the cluster](https://github.com/konflux-ci/konflux-ci?tab=readme-ov-file#bootstrapping-the-cluster)
- [Enabling Pipelines Triggering via Webhooks](https://github.com/konflux-ci/konflux-ci?tab=readme-ov-file#enable-pipelines-triggering-via-webhooks)

NOTE: You will need to configure your repository with the Pipelines as Code application, so make sure you don't lose track of it when you create it.

Create two namespaces on your cluster.
  - One is a tenant namespace where the artifact builds will occur
  - One is a managed namespace which will be where privileged operations occur

Install the required cli tools for this demo:
- [cosign](https://github.com/sigstore/cosign?tab=readme-ov-file#installation), a tool for fetching attestations for OCI artifacts
- [helm](https://github.com/helm/helm?tab=readme-ov-file#install) to deploy the resources to the KindD cluster
- [tkn](https://github.com/tektoncd/cli?tab=readme-ov-file#installing-tkn) to view Tekton pipelines

- (Optional) create push credentials for two different image repositories.

## Setting up your builds

In order to achieve [SLSA build L3](https://slsa.dev/spec/v1.1/requirements), we need to ensure that builds are properly isolated
both from other builds as well as from the secrets used to sign the provenance. Konflux relies on Kubernetes pods, as orchestrated by
Tekton, to ensure that parallel builds are sufficiently isolated from each other. It also relies on Kubernetes namespace isolation to
ensure that the signing material that Tekton Chains uses when generating the provenance cannot be accessed by builds.

Configuring the required Tekton definition can be onerous, so we use Pipelines as Code to help push out a default definition when you
onboard a component.

## Setup your repository

In this phase, we will walk you through what is needed to get your source repository ready to explore SLSA, Konflux style.

## Onboard the component

Once your Konflux instance is deployed, we need to make sure that your tenant and managed namespaces are configured. This not only includes
configuring Pipelines as Code so that you can create builds from your git commits, but also ensuring that we have the necessary configuration
to test and release all of the artifacts you build.

```bash
helm [...]
```

Now that you have onboarded your component, your PR will report a running build and you can use `tkn` to see it in the cluster! Let's merge that
PR, let the build run, and then look at what all just happened.
