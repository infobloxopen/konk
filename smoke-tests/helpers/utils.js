// Common utilities: parsing, logging, naming, polling.
import { sleep } from 'k6';
import http from 'k6/http';
import {
  HTTP_PARAMS_BASE,
  RECONCILE_TIMEOUT_S,
  POLL_INTERVAL_S,
  DEPLOYED_REASON_REGEX,
  KUBE_USE_PROXY,
} from '../config/config.js';

// ---- Parsing ----
export const parseBody = (r) => {
  try {
    return JSON.parse(r.body);
  } catch (e) {
    return {};
  }
};

// ---- Logging ----
export function logRequest(phase, endpoint, method, url, payload, response) {
  let bodyOut = '';
  try {
    bodyOut = response && response.body ? String(response.body) : '';
    if (bodyOut.length > 2000) bodyOut = bodyOut.slice(0, 2000) + '...[truncated]';
  } catch (e) {
    bodyOut = '';
  }
  const reqHeaders = KUBE_USE_PROXY
    ? { Authorization: '<omitted: kubectl proxy>' }
    : { Authorization: 'Bearer ***redacted***' };
  console.log(
    JSON.stringify({
      phase,
      endpoint,
      method,
      url,
      requestHeaders: reqHeaders,
      requestPayload: payload || null,
      status: response ? response.status : null,
      responseBody: bodyOut,
    }),
  );
}

export function logSkip(scenarioId, endpoint, reason) {
  console.log(
    JSON.stringify({ phase: 'execution', scenario: scenarioId, endpoint, skipped: true, reason }),
  );
}

export function safeBody(body) {
  if (!body) return null;
  try {
    return JSON.parse(body);
  } catch (e) {
    return String(body).slice(0, 500);
  }
}

// ---- Naming (RFC1123-safe AUTO_TEST_ form) ----
export function rand6() {
  return Math.random().toString(36).slice(2, 8);
}
export function uniqueSuffix(scenarioId) {
  return `${scenarioId.toLowerCase()}-${Date.now()}-${__VU}-${rand6()}`;
}
function rfc1123(name) {
  let n = name.toLowerCase().replace(/[^a-z0-9-]/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '');
  if (n.length > 63) n = n.slice(0, 63).replace(/-$/, '');
  return n;
}
export function autoTestName(scenarioId, hint) {
  return rfc1123(`auto-test-${hint || ''}-${uniqueSuffix(scenarioId)}`);
}
export function autoTestNamespace() {
  return rfc1123(`auto-test-konk-${Date.now()}-${__VU}-${rand6()}`);
}

// ---- HTTP wrappers (always log) ----
function withHeaders(token, extra = {}) {
  const baseHeaders = {
    'Content-Type': 'application/json',
    Accept: 'application/json',
  };
  // Suppress Authorization when going through `kubectl proxy` (it uses the
  // caller's kubeconfig identity and forwards any Authorization header verbatim).
  if (!KUBE_USE_PROXY && token) baseHeaders.Authorization = `Bearer ${token}`;
  return Object.assign(
    {},
    HTTP_PARAMS_BASE,
    { headers: Object.assign(baseHeaders, extra.headers || {}) },
    extra,
  );
}

export function kget(token, url, endpointName) {
  const r = http.get(url, withHeaders(token));
  logRequest('execution', endpointName, 'GET', url, null, r);
  return r;
}
export function kpost(token, url, body, endpointName) {
  const r = http.post(url, body, withHeaders(token));
  logRequest('execution', endpointName, 'POST', url, safeBody(body), r);
  return r;
}
export function kput(token, url, body, endpointName) {
  const r = http.put(url, body, withHeaders(token));
  logRequest('execution', endpointName, 'PUT', url, safeBody(body), r);
  return r;
}
export function kpatch(token, url, body, endpointName, contentType = 'application/merge-patch+json') {
  const r = http.patch(url, body, withHeaders(token, { headers: { 'Content-Type': contentType } }));
  logRequest('execution', endpointName, 'PATCH', url, safeBody(body), r);
  return r;
}
export function kdelete(token, url, endpointName) {
  const r = http.del(url, null, withHeaders(token));
  logRequest('execution', endpointName, 'DELETE', url, null, r);
  return r;
}

// ---- Polling ----
export function pollDeployed(token, getUrl, endpointName) {
  const deadline = Date.now() + RECONCILE_TIMEOUT_S * 1000;
  let last = null;
  while (Date.now() < deadline) {
    last = kget(token, getUrl, endpointName);
    if (last.status === 200) {
      const body = parseBody(last);
      const conds = (body.status && body.status.conditions) || [];
      const deployed = conds.find((c) => c.type === 'Deployed');
      if (deployed && deployed.status === 'True' && DEPLOYED_REASON_REGEX.test(deployed.reason || '')) {
        return { ok: true, response: last, condition: deployed };
      }
    }
    sleep(POLL_INTERVAL_S);
  }
  return { ok: false, response: last };
}

export function pollDeleted(token, getUrl, endpointName) {
  const deadline = Date.now() + RECONCILE_TIMEOUT_S * 1000;
  let last = null;
  while (Date.now() < deadline) {
    last = kget(token, getUrl, endpointName);
    if (last.status === 404) return { ok: true, response: last };
    sleep(POLL_INTERVAL_S);
  }
  return { ok: false, response: last };
}
