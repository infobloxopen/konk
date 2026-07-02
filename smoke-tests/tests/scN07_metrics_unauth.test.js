// SC-N-07: Operator metrics endpoint without/with-bad token (CONDITIONAL).
import http from 'k6/http';
import { check } from 'k6';
import { METRICS_URL, KUBE_INSECURE_SKIP_TLS_VERIFY } from '../config/config.js';
import { logRequest, logSkip } from '../helpers/utils.js';
import { isUnauthorized, isForbidden } from '../helpers/validators.js';

export function runSCN07() {
  const sid = 'SC-N-07';
  if (!METRICS_URL) {
    logSkip(sid, 'operator_metrics', 'METRICS_URL not provided (conditional scenario)');
    return;
  }
  const url = METRICS_URL.endsWith('/metrics') ? METRICS_URL : `${METRICS_URL}/metrics`;

  // No auth
  const r1 = http.get(url, { timeout: '30s', insecureSkipTLSVerify: KUBE_INSECURE_SKIP_TLS_VERIFY });
  logRequest('execution', 'operator_metrics_noauth', 'GET', url, null, r1);
  check(r1, {
    'SC-N-07 metrics noauth 401/403': (r) => isUnauthorized(r) || isForbidden(r),
  });

  // Bad token
  const r2 = http.get(url, {
    headers: { Authorization: 'Bearer invalid.invalid.invalid' },
    timeout: '30s',
    insecureSkipTLSVerify: KUBE_INSECURE_SKIP_TLS_VERIFY,
  });
  logRequest('execution', 'operator_metrics_badauth', 'GET', url, null, r2);
  check(r2, {
    'SC-N-07 metrics bad token 401/403': (r) => isUnauthorized(r) || isForbidden(r),
  });
}
