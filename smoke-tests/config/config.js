// Centralized configuration for konk smoke tests.
// All values come from environment variables; no credentials hardcoded.

export const ALLOWED_CLUSTERS = (__ENV.ALLOWED_CLUSTERS || 'us-dev-5')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

export const TARGET_CLUSTER = (__ENV.TARGET_CLUSTER || 'us-dev-5').trim();

// Kube API
export const KUBE_API_URL = (__ENV.KUBE_API_URL || '').replace(/\/$/, '');
export const KUBE_BEARER_TOKEN = __ENV.KUBE_BEARER_TOKEN || '';
export const KUBE_INSECURE_SKIP_TLS_VERIFY =
  (__ENV.KUBE_INSECURE_SKIP_TLS_VERIFY || 'false').toLowerCase() === 'true';
// When true, the kube API is reached through `kubectl proxy` (which uses the
// caller's kubeconfig identity). In this mode we MUST NOT send Authorization
// headers because the proxy forwards them verbatim and they will fail auth.
export const KUBE_USE_PROXY =
  (__ENV.KUBE_USE_PROXY || 'false').toLowerCase() === 'true';

// Optional generic JWT auth (per prompt spec)
export const AUTH_MODE = (__ENV.AUTH_MODE || 'kube').toLowerCase(); // 'kube' | 'jwt'
export const BASE_URL = (__ENV.BASE_URL || '').replace(/\/$/, '');
export const USER_EMAIL = __ENV.USER_EMAIL || '';
export const USER_PASSWORD = __ENV.USER_PASSWORD || '';

// Conditional metrics endpoint
export const METRICS_URL = (__ENV.METRICS_URL || '').replace(/\/$/, '');
export const METRICS_TOKEN = __ENV.METRICS_TOKEN || '';

// Reconciliation polling (per smoke-test-plan verification_strategy.polling)
export const RECONCILE_TIMEOUT_S = parseInt(__ENV.RECONCILE_TIMEOUT_S || '300', 10);
export const POLL_INTERVAL_S = parseInt(__ENV.POLL_INTERVAL_S || '5', 10);
export const DEPLOYED_REASON_REGEX = /^(Install|Upgrade)?Successful$/;

// CRD coordinates
export const API_GROUP = 'konk.infoblox.com';
export const API_VERSION = 'v1alpha1';

// HTTP defaults shared by all calls
export const HTTP_PARAMS_BASE = {
  timeout: '60s',
  insecureSkipTLSVerify: KUBE_INSECURE_SKIP_TLS_VERIFY,
};

// URL builders
export function nsBase(ns) {
  return `${KUBE_API_URL}/apis/${API_GROUP}/${API_VERSION}/namespaces/${ns}`;
}
export const u = {
  konks: (ns) => `${nsBase(ns)}/konks`,
  konk: (ns, name) => `${nsBase(ns)}/konks/${name}`,
  konkStatus: (ns, name) => `${nsBase(ns)}/konks/${name}/status`,
  konkservices: (ns) => `${nsBase(ns)}/konkservices`,
  konkservice: (ns, name) => `${nsBase(ns)}/konkservices/${name}`,
  konkserviceStatus: (ns, name) => `${nsBase(ns)}/konkservices/${name}/status`,
  etcds: (ns) => `${nsBase(ns)}/etcds`,
  etcd: (ns, name) => `${nsBase(ns)}/etcds/${name}`,
  namespace: (ns) => `${KUBE_API_URL}/api/v1/namespaces/${ns}`,
  namespaces: () => `${KUBE_API_URL}/api/v1/namespaces`,
};
