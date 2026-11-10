# Demo utility image: curl + the SPIRE spire-agent binary in one image, so
# demo tasks can fetch a JWT-SVID and immediately USE it in a single step
# (the official spire-agent image is distroless: stdout only, no shell).
#
# Built and pushed to the in-cluster registry by demo/setup-demo.sh (see
# demo/vault-setup-lib.sh publish_demo_utility_image).
FROM docker.io/library/alpine:3.20
COPY --from=ghcr.io/spiffe/spire-agent:1.15.3 /opt/spire/bin/spire-agent /usr/local/bin/spire-agent
RUN apk add --no-cache curl jq
# Smoke-test the binary so a bad build fails fast.
RUN spire-agent --version && curl --version | head -n1
