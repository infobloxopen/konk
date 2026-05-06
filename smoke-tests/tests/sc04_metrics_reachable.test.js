// SC-04: Operator metrics endpoint reachable with valid token (CONDITIONAL).
// Skipped if METRICS_URL or METRICS_TOKEN env vars are unset.
import http from 'k6/http';
import { check } from 'k6';
import { METRICS_URL, METRICS_TOKEN, KUBE_INSECURE_SKIP_TLS_VERIFY } from '../config/config.js';
import { logRequest, logSkip } from '../helpers/utils.js';
import { isOk, isPromExposition } from '../helpers/validators.js';

export function runSC04() {
  const sid = 'SC-04';
  if (!METRICS_URL || !METRICS_TOKEN) {
    logSkip(sid, 'operator_metrics', 'METRICS_URL or METRICS_TOKEN not provided (conditional scenario)');
    return;
  }
  const url = METRICS_URL.endsWith('/metrics') ? METRICS_URL : `${METRICS_URL}/metrics`;
  const r = http.get(url, {
    headers: { Authorization: `Bearer ${METRICS_TOKEN}` },
    timeout: '30s',
    insecureSkipTLSVerify: KUBE_INSECURE_SKIP_TLS_VERIFY,
  });
  logRequest('execution', 'operator_metrics', 'GET', url, null, r);
  check(r, {
    'SC-04 metrics 200': isOk,
    'SC-04 metrics is Prometheus exposition': isPromExposition,
  });
}
