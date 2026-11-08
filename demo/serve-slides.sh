#!/usr/bin/env bash
# ==============================================================================
# Helper Script: Serve Live Demo Instances for Slide Presentation via ttyd
#
# Launches individual ttyd web-terminal servers at predefined ports,
# binding each instance to a specific demo act while keeping the session
# open upon act completion so connections never drop.
#
# Port Mapping:
#   7681 -> Act 1: Admission & Separation of Duties Attestations
#   7682 -> Act 2: Ambient Push Hijack vs. Task-Scoped OCI Push Gating
#   7683 -> Act 3: Portable Secretless Service Access (CVE Database)
#   7684 -> Act 4: Managed Release Boundary (Dual-Gated Authority)
#   7680 -> Full Arc (Acts 0 - 4 end-to-end)
# ==============================================================================
set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
PID_FILE="/tmp/kubecon-demo-ttyd.pids"
CUSTOM_INDEX="/tmp/ttyd-slide-index.html"

# Colors for output
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

check_prereqs() {
  if ! command -v ttyd >/dev/null 2>&1; then
    echo -e "${RED}[Error] 'ttyd' is not installed.${NC}"
    echo "Install it via Homebrew on macOS:"
    echo "  brew install ttyd"
    exit 1
  fi
}

is_port_listening() {
  local port="$1"
  lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

kill_port_owner() {
  local port="$1"
  local pid
  pid=$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
  if [[ -n "$pid" ]]; then
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi
}

prepare_custom_index() {
  if [[ -f "$CUSTOM_INDEX" ]] && grep -q "DEMO_ESCAPE" "$CUSTOM_INDEX" 2>/dev/null; then
    return 0
  fi

  echo -e "${CYAN}==> [Slide Server] Generating slide-aware terminal index...${NC}"
  local temp_port=7699
  while lsof -iTCP:"$temp_port" -sTCP:LISTEN >/dev/null 2>&1; do
    temp_port=$((temp_port + 1))
  done

  nohup ttyd --port "$temp_port" --interface 127.0.0.1 echo ready >/dev/null 2>&1 &
  local tmp_pid=$!

  local raw_html=""
  local attempts=0
  while [[ $attempts -lt 30 ]]; do
    if raw_html=$(curl -s "http://127.0.0.1:${temp_port}/" 2>/dev/null) && [[ -n "$raw_html" ]]; then
      break
    fi
    sleep 0.1
    attempts=$((attempts + 1))
  done

  kill -9 "$tmp_pid" >/dev/null 2>&1 || true

  if [[ -z "$raw_html" ]]; then
    echo -e "${YELLOW}[Warning] Could not extract ttyd HTML template; proceeding with default index.${NC}"
    CUSTOM_INDEX=""
    return 0
  fi

  python3 -c "
import sys

raw = sys.stdin.read()
script = '''<script>
(function() {
  'use strict';
  function signalToParent(type, data) {
    if (window.parent && window.parent !== window) {
      window.parent.postMessage(Object.assign({ type: type }, data || {}), '*');
    }
  }
  function blurTerminal() {
    if (document.activeElement && typeof document.activeElement.blur === 'function') {
      document.activeElement.blur();
    }
  }

  // Intercept Escape in capture phase before xterm consumes it
  window.addEventListener('keydown', function(e) {
    if (e.key === 'Escape' || e.keyCode === 27) {
      e.preventDefault();
      e.stopPropagation();
      blurTerminal();
      signalToParent('DEMO_ESCAPE');
    }
  }, true);
  document.addEventListener('keydown', function(e) {
    if (e.key === 'Escape' || e.keyCode === 27) {
      e.preventDefault();
      e.stopPropagation();
      blurTerminal();
      signalToParent('DEMO_ESCAPE');
    }
  }, true);

  // Monitor title changes for act completion escape sequences
  var lastTitle = document.title;
  var checkTitle = function() {
    var cur = document.title || '';
    if (cur !== lastTitle) {
      lastTitle = cur;
      if (cur.indexOf('COMPLETE') !== -1) {
        blurTerminal();
        signalToParent('DEMO_ACT_COMPLETE', { title: cur });
      }
    }
  };
  var observer = new MutationObserver(checkTitle);
  var titleEl = document.querySelector('title');
  if (titleEl) {
    observer.observe(titleEl, { subtree: true, characterData: true, childList: true });
  }
  setInterval(checkTitle, 300);
})();
</script>'''

if '</body>' in raw:
    out = raw.replace('</body>', script + '</body>')
else:
    out = raw + script

with open('${CUSTOM_INDEX}', 'w', encoding='utf-8') as f:
    f.write(out)
" <<< "$raw_html"
}

start_instances() {
  check_prereqs

  # Ensure demo baseline is primed
  echo -e "${CYAN}==> [Slide Server] Verifying demo baseline...${NC}"
  "${DIR}/setup-demo.sh" >/dev/null 2>&1

  # Stop any stale instances
  stop_instances >/dev/null 2>&1 || true

  # Ensure slide-aware index is prepared
  prepare_custom_index

  echo -e "${CYAN}==> [Slide Server] Launching ttyd instances on predefined ports...${NC}"

  declare -A ACT_PORTS=(
    [0]="7680"
    [1]="7681"
    [2]="7682"
    [3]="7683"
    [4]="7684"
  )

  declare -A ACT_DESCS=(
    [0]="Full Demo Arc (Acts 0 - 4)"
    [1]="Act 1: Admission & Separation of Duties"
    [2]="Act 2: Ambient Hijack vs. OCI Gating"
    [3]="Act 3: Secretless Service Access"
    [4]="Act 4: Dual-Gated Release Authority"
  )

  true > "$PID_FILE"

  local index_arg=()
  if [[ -n "${CUSTOM_INDEX}" && -f "${CUSTOM_INDEX}" ]]; then
    index_arg=("-I" "${CUSTOM_INDEX}")
  fi

  for act in 0 1 2 3 4; do
    port="${ACT_PORTS[$act]}"
    kill_port_owner "$port"

    # Command drops into interactive shell upon completion so WebSocket stays alive
    cmd="cd '${DIR}' && ./run-demo.sh --act ${act}; echo ''; echo '==> Session preserved. Press ENTER or type commands:'; exec bash"

    # Start ttyd with clean styling and font size
    nohup ttyd \
      --port "$port" \
      --interface 127.0.0.1 \
      --writable \
      "${index_arg[@]}" \
      -t fontSize=15 \
      -t fontFamily="Ubuntu Mono, Menlo, monospace" \
      -t theme='{"background": "#1e1e2e", "foreground": "#cdd6f4", "cursor": "#f5e0dc"}' \
      bash -c "$cmd" >/dev/null 2>&1 &

    pid=$!
    echo "$pid" >> "$PID_FILE"
  done

  # Small sleep to allow bindings to settle
  sleep 1

  echo ""
  echo -e "${GREEN}═════════════════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Slide Demo Server Active! ttyd Web Terminals Ready.                             ${NC}"
  echo -e "${GREEN}═════════════════════════════════════════════════════════════════════════════════${NC}"
  echo ""
  printf "%-8s %-12s %-42s %-30s\n" "PORT" "ACT" "TOPIC" "BROWSER ENDPOINT"
  echo "─────────────────────────────────────────────────────────────────────────────────"
  for act in 1 2 3 4 0; do
    port="${ACT_PORTS[$act]}"
    desc="${ACT_DESCS[$act]}"
    url="http://localhost:${port}"
    printf "%-8s %-12s %-42s %-30s\n" "$port" "Act $act" "$desc" "$url"
  done
  echo "─────────────────────────────────────────────────────────────────────────────────"
  echo ""
  echo -e "Embed in slides using: ${CYAN}<iframe src=\"http://localhost:7681\"></iframe>${NC}"
  echo -e "To stop all instances: ${YELLOW}./demo/serve-slides.sh stop${NC}"
}

stop_instances() {
  echo -e "${CYAN}==> [Slide Server] Stopping ttyd instances...${NC}"
  if [[ -f "$PID_FILE" ]]; then
    while read -r pid; do
      if [[ -n "$pid" ]]; then
        kill "$pid" >/dev/null 2>&1 || true
      fi
    done < "$PID_FILE"
    rm -f "$PID_FILE"
  fi

  for port in 7680 7681 7682 7683 7684; do
    kill_port_owner "$port"
  done

  echo -e "${GREEN}==> All slide demo instances stopped.${NC}"
}

status_instances() {
  echo -e "${CYAN}==> [Slide Server] Checking instance status...${NC}"
  printf "%-8s %-12s %-30s %-10s\n" "PORT" "ACT" "BROWSER ENDPOINT" "STATUS"
  echo "─────────────────────────────────────────────────────────────"
  for act in 1 2 3 4 0; do
    port=$(( act == 0 ? 7680 : 7680 + act ))
    url="http://localhost:${port}"
    if is_port_listening "$port"; then
      status="${GREEN}RUNNING${NC}"
    else
      status="${RED}STOPPED${NC}"
    fi
    printf "%-8s %-12s %-30s " "$port" "Act $act" "$url"
    echo -e "$status"
  done
  echo "─────────────────────────────────────────────────────────────"
}

case "${1:-start}" in
  start)
    start_instances
    ;;
  stop)
    stop_instances
    ;;
  restart)
    stop_instances
    start_instances
    ;;
  status)
    status_instances
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}"
    exit 1
    ;;
esac
