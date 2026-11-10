#!/usr/bin/env bash
# Demo tool bootstrap: ensure the host tools the demo needs (tkn, cosign)
# are available, downloading them into demo/.tools/ (gitignored) with the
# user's permission when they are not on PATH. Nothing is installed
# system-wide and no shell config is modified.
#
# Usage (from another demo script, after sourcing kubeconfig.sh):
#   source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"
#   ensure_demo_tools tkn cosign || <graceful skip>
#
# The function prepends demo/.tools/ to PATH when tools are fetched, and is
# idempotent: existing .tools/ binaries are reused without prompting.

TOOLS_LIB_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
DEMO_TOOLS_DIR="${DEMO_TOOLS_DIR:-${TOOLS_LIB_DIR}/.tools}"

_download_tkn() {
  # tektoncd/cli release assets: tkn_<ver>_<Darwin|Linux>_<arm64|x86_64>.tar.gz
  local os arch ver tag tarball tmp
  os=$(uname -s); arch=$(uname -m)
  case "${os}" in
    Darwin) os="Darwin" ;;
    *) os="Linux" ;;
  esac
  ver=$(curl -fsSL https://api.github.com/repos/tektoncd/cli/releases/latest \
    | python3 -c "import sys, json; print(json.load(sys.stdin)['tag_name'])") || return 1
  tag="${ver#v}"
  tarball="tkn_${tag}_${os}_${arch}.tar.gz"
  tmp=$(mktemp -d)
  curl -fsSL -o "${tmp}/tkn.tgz" \
    "https://github.com/tektoncd/cli/releases/download/${ver}/${tarball}" || { rm -rf "${tmp}"; return 1; }
  tar -xzf "${tmp}/tkn.tgz" -C "${tmp}" tkn || { rm -rf "${tmp}"; return 1; }
  mv "${tmp}/tkn" "${DEMO_TOOLS_DIR}/tkn" && chmod +x "${DEMO_TOOLS_DIR}/tkn"
  rm -rf "${tmp}"
}

_download_cosign() {
  # sigstore/cosign release assets: cosign-<os>-<arch> (single binary)
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$(uname -m)
  case "${arch}" in
    x86_64) arch="amd64" ;;
    aarch64) arch="arm64" ;;
  esac
  curl -fsSL -o "${DEMO_TOOLS_DIR}/cosign" \
    "https://github.com/sigstore/cosign/releases/latest/download/cosign-${os}-${arch}" \
    && chmod +x "${DEMO_TOOLS_DIR}/cosign"
}

_download_tool() {
  local tool="$1"
  case "${tool}" in
    tkn) _download_tkn ;;
    cosign) _download_cosign ;;
    *) echo "tools.sh: no download recipe for '${tool}'" >&2; return 1 ;;
  esac
}

ensure_demo_tools() {
  local missing=() tool
  for tool in "$@"; do
    command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
  done
  [ ${#missing[@]} -eq 0 ] && return 0

  # Already fetched in a previous run?
  local found_all=true
  for tool in "${missing[@]}"; do
    [ -x "${DEMO_TOOLS_DIR}/${tool}" ] || found_all=false
  done
  if [ "${found_all}" == "true" ]; then
    export PATH="${DEMO_TOOLS_DIR}:${PATH}"
    return 0
  fi

  # Permissioned fetch: never touch the broader system.
  echo "Missing tools: ${missing[*]}"
  if [ ! -t 0 ]; then
    echo "Non-interactive session; not fetching. Install them on PATH or re-run"
    echo "setup in an interactive terminal to fetch them into ${DEMO_TOOLS_DIR}."
    return 1
  fi
  read -p "Download into ${DEMO_TOOLS_DIR} (gitignored, no system install)? [y/N]: " -r RESP
  if [[ ! "${RESP}" =~ ^[Yy]$ ]]; then
    echo "Skipped by user."
    return 1
  fi

  mkdir -p "${DEMO_TOOLS_DIR}"
  for tool in "${missing[@]}"; do
    if [ -x "${DEMO_TOOLS_DIR}/${tool}" ]; then continue; fi
    echo "Fetching ${tool}..."
    _download_tool "${tool}" || { echo "Failed to fetch ${tool}." >&2; return 1; }
    "${DEMO_TOOLS_DIR}/${tool}" --version >/dev/null 2>&1 || true
  done
  export PATH="${DEMO_TOOLS_DIR}:${PATH}"

  # Verify everything resolved.
  for tool in "$@"; do
    command -v "${tool}" >/dev/null 2>&1 || return 1
  done
  return 0
}
