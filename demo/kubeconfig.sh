#!/usr/bin/env bash
# Shared kubeconfig discovery for the demo scripts.
#
# The Konflux demo cluster (kind) is reachable via a dedicated kubeconfig
# (~/.kube/config-kind by default, matching what the konflux-ci/konflux-ci
# setup produces). Source this file from a demo script BEFORE its first
# kubectl call: if the ambient kubectl already targets the Konflux cluster
# it is left untouched; otherwise known kubeconfig candidates are tried and
# the first one that reaches the demo cluster is exported.
#
# Scripts that do not define fail() get a local fallback.

# Probe: does kubectl (with the given KUBECONFIG, if any) reach the demo
# cluster? The default-tenant namespace only exists on the Konflux cluster.
_konflux_kubeconfig_ok() {
  KUBECONFIG="${1:-${KUBECONFIG:-}}" kubectl get namespace default-tenant >/dev/null 2>&1
}

if ! _konflux_kubeconfig_ok; then
  for _kc in "${KIND_KUBECONFIG:-}" "${HOME}/.kube/config-kind" "${HOME}/.kube/config"; do
    [ -n "${_kc}" ] && [ -f "${_kc}" ] || continue
    if _konflux_kubeconfig_ok "${_kc}"; then
      export KUBECONFIG="${_kc}"
      break
    fi
  done
fi

if ! _konflux_kubeconfig_ok; then
  if command -v fail >/dev/null 2>&1; then
    fail "Cannot connect to the Konflux demo cluster. Tried KUBECONFIG='${KUBECONFIG:-<unset>}', ${KIND_KUBECONFIG:-unset}, ~/.kube/config-kind, ~/.kube/config. Start the kind cluster (and Podman VM) or export KUBECONFIG."
  else
    echo "Error: Cannot connect to the Konflux demo cluster." >&2
    echo "Tried: KUBECONFIG='${KUBECONFIG:-<unset>}', ${KIND_KUBECONFIG:-unset}, ~/.kube/config-kind, ~/.kube/config" >&2
    exit 1
  fi
fi

unset -f _konflux_kubeconfig_ok
