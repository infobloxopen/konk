#!/usr/bin/env bash
# Self-contained smoke runner.
# Starts `kubectl proxy` on a free port, runs the k6 suite against it, and
# always cleans up the proxy on exit (success, failure, or Ctrl-C).
#
# Usage:
#   ./smoke-tests/run.sh                       # default: TARGET_CLUSTER=us-dev-5
#   TARGET_CLUSTER=us-dev-5 ./smoke-tests/run.sh
#   PORT=8765 ./smoke-tests/run.sh             # use a specific port
#   K6_BIN=/opt/homebrew/bin/k6 ./smoke-tests/run.sh
#
# Pass-through env vars (forwarded to k6):
#   ALLOWED_CLUSTERS, METRICS_URL, METRICS_TOKEN, RECONCILE_TIMEOUT_S,
#   POLL_INTERVAL_S, KUBE_INSECURE_SKIP_TLS_VERIFY
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_JS="${SCRIPT_DIR}/main.js"
K6_BIN="${K6_BIN:-k6}"
TARGET_CLUSTER="${TARGET_CLUSTER:-us-dev-5}"
ALLOWED_CLUSTERS="${ALLOWED_CLUSTERS:-${TARGET_CLUSTER}}"
PORT="${PORT:-}"

command -v kubectl >/dev/null || { echo "kubectl not found in PATH" >&2; exit 127; }
command -v "${K6_BIN}" >/dev/null || { echo "k6 not found (set K6_BIN)" >&2; exit 127; }
[[ -f "${MAIN_JS}" ]] || { echo "main.js not found at ${MAIN_JS}" >&2; exit 1; }

# Verify cluster context is in the allowlist BEFORE we touch the cluster.
CTX="$(kubectl config current-context 2>/dev/null || true)"
if [[ -z "${CTX}" ]]; then
  echo "no current kube-context" >&2; exit 1
fi
if ! grep -q -- "${TARGET_CLUSTER}" <<< "${CTX}"; then
  echo "WARNING: current kube-context '${CTX}' does not contain TARGET_CLUSTER='${TARGET_CLUSTER}'" >&2
fi

# Pick a free port if not provided.
if [[ -z "${PORT}" ]]; then
  PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
fi

PROXY_LOG="$(mktemp -t konk-smoke-proxy.XXXXXX.log)"
PROXY_PID=""

cleanup() {
  local rc=$?
  if [[ -n "${PROXY_PID}" ]] && kill -0 "${PROXY_PID}" 2>/dev/null; then
    echo "[run.sh] stopping kubectl proxy (pid=${PROXY_PID})"
    kill "${PROXY_PID}" 2>/dev/null || true
    wait "${PROXY_PID}" 2>/dev/null || true
  fi
  rm -f "${PROXY_LOG}" 2>/dev/null || true
  exit "${rc}"
}
trap cleanup EXIT INT TERM

echo "[run.sh] starting kubectl proxy on 127.0.0.1:${PORT} (context=${CTX})"
kubectl proxy --port="${PORT}" --address=127.0.0.1 --accept-hosts='^127\.0\.0\.1$' \
  >"${PROXY_LOG}" 2>&1 &
PROXY_PID=$!

# Wait for proxy to become reachable (max 10s).
for i in $(seq 1 50); do
  if curl -sf "http://127.0.0.1:${PORT}/readyz" >/dev/null 2>&1 \
     || curl -sf "http://127.0.0.1:${PORT}/api" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
  if ! kill -0 "${PROXY_PID}" 2>/dev/null; then
    echo "[run.sh] kubectl proxy exited prematurely. Log:" >&2
    cat "${PROXY_LOG}" >&2
    exit 1
  fi
done

echo "[run.sh] proxy ready -> http://127.0.0.1:${PORT}"
echo "[run.sh] running k6 ..."

"${K6_BIN}" run "${MAIN_JS}" \
  -e "KUBE_API_URL=http://127.0.0.1:${PORT}" \
  -e "KUBE_USE_PROXY=true" \
  -e "TARGET_CLUSTER=${TARGET_CLUSTER}" \
  -e "ALLOWED_CLUSTERS=${ALLOWED_CLUSTERS}" \
  ${METRICS_URL:+-e "METRICS_URL=${METRICS_URL}"} \
  ${METRICS_TOKEN:+-e "METRICS_TOKEN=${METRICS_TOKEN}"} \
  ${RECONCILE_TIMEOUT_S:+-e "RECONCILE_TIMEOUT_S=${RECONCILE_TIMEOUT_S}"} \
  ${POLL_INTERVAL_S:+-e "POLL_INTERVAL_S=${POLL_INTERVAL_S}"} \
  ${KUBE_INSECURE_SKIP_TLS_VERIFY:+-e "KUBE_INSECURE_SKIP_TLS_VERIFY=${KUBE_INSECURE_SKIP_TLS_VERIFY}"}
