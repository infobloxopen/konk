// k6 smoke test entry point for konk.
// Orchestrates setup -> scenarios -> teardown with strict AUTO_TEST_ guardrails.

import { check, fail } from 'k6';
import {
  ALLOWED_CLUSTERS,
  TARGET_CLUSTER,
  KUBE_API_URL,
  u,
  API_GROUP,
  API_VERSION,
} from './config/config.js';
import {
  autoTestNamespace,
  kpost,
  kget,
  kdelete,
  pollDeleted,
} from './helpers/utils.js';
import { authToken } from './helpers/auth.js';
import { safeDelete } from './helpers/resourceHelpers.js';

import { runSC01 } from './tests/sc01_konk_lifecycle.test.js';
import { runSC02 } from './tests/sc02_konkservice_lifecycle.test.js';
import { runSC03 } from './tests/sc03_etcd_lifecycle.test.js';
import { runSC04 } from './tests/sc04_metrics_reachable.test.js';
import { runSCN01 } from './tests/scN01_reject_invalid_scope.test.js';
import { runSCN02 } from './tests/scN02_reject_konkservice_invalid.test.js';
import { runSCN03 } from './tests/scN03_reject_unauth_create.test.js';
import { runSCN04 } from './tests/scN04_get_missing_404.test.js';
import { runSCN05 } from './tests/scN05_delete_missing_404.test.js';
import { runSCN06 } from './tests/scN06_reject_missing_namespace.test.js';
import { runSCN07 } from './tests/scN07_metrics_unauth.test.js';

export const options = {
  scenarios: {
    smoke: { executor: 'per-vu-iterations', vus: 1, iterations: 1, maxDuration: '20m' },
  },
  setupTimeout: '2m',
  teardownTimeout: '5m',
  thresholds: { checks: ['rate>=0.95'] },
};

// ---------- setup ----------
export function setup() {
  console.log(JSON.stringify({ phase: 'setup', step: 'cluster_allowlist_check', cluster: TARGET_CLUSTER, allowed: ALLOWED_CLUSTERS }));
  if (!ALLOWED_CLUSTERS.includes(TARGET_CLUSTER)) {
    fail(`TARGET_CLUSTER='${TARGET_CLUSTER}' is not in ALLOWED_CLUSTERS=${JSON.stringify(ALLOWED_CLUSTERS)}`);
  }
  if (!KUBE_API_URL) fail('KUBE_API_URL is required');

  const token = authToken();

  // Connectivity probe: list konks at cluster scope (any-ns) by hitting /apis discovery.
  const probeUrl = `${KUBE_API_URL}/apis/${API_GROUP}/${API_VERSION}`;
  const probe = kget(token, probeUrl, 'apigroup_discovery');
  check(probe, { 'setup: konk apigroup reachable': (r) => r.status === 200 });
  if (probe.status !== 200) {
    fail(`setup: cannot reach ${API_GROUP}/${API_VERSION} discovery (status=${probe.status})`);
  }

  // Create dedicated AUTO_TEST namespace
  const ns = autoTestNamespace();
  const nsBody = JSON.stringify({
    apiVersion: 'v1',
    kind: 'Namespace',
    metadata: { name: ns, labels: { 'auto-test': 'true' } },
  });
  const created = kpost(token, u.namespaces(), nsBody, 'namespace_create');
  check(created, { 'setup: namespace created (201)': (r) => r.status === 201 });
  if (created.status !== 201) {
    fail(`setup: failed to create namespace '${ns}' (status=${created.status})`);
  }

  return { token, ns };
}

// ---------- default ----------
export default function (data) {
  const ctx = {
    token: data.token,
    ns: data.ns,
    created: { konks: [], konkservices: [], etcds: [] },
  };

  // Wrap in try/finally so inline cleanup always runs, even if a scenario
  // throws an uncaught error. teardown() is the second safety net (namespace).
  try {
    // Positive
    try { runSC01(ctx); } catch (e) { console.log(`SC-01 threw: ${e}`); }
    try { runSC02(ctx); } catch (e) { console.log(`SC-02 threw: ${e}`); }
    try { runSC03(ctx); } catch (e) { console.log(`SC-03 threw: ${e}`); }
    try { runSC04(ctx); } catch (e) { console.log(`SC-04 threw: ${e}`); }

    // Negative
    try { runSCN01(ctx); } catch (e) { console.log(`SC-N-01 threw: ${e}`); }
    try { runSCN02(ctx); } catch (e) { console.log(`SC-N-02 threw: ${e}`); }
    try { runSCN03(ctx); } catch (e) { console.log(`SC-N-03 threw: ${e}`); }
    try { runSCN04(ctx); } catch (e) { console.log(`SC-N-04 threw: ${e}`); }
    try { runSCN05(ctx); } catch (e) { console.log(`SC-N-05 threw: ${e}`); }
    try { runSCN06(ctx); } catch (e) { console.log(`SC-N-06 threw: ${e}`); }
    try { runSCN07(ctx); } catch (e) { console.log(`SC-N-07 threw: ${e}`); }
  } finally {
    // Inline cleanup of CRs created during this iteration. Order: KonkService -> Etcd -> Konk.
    inlineCleanup(ctx);
  }
}

function inlineCleanup(ctx) {
  console.log(JSON.stringify({ phase: 'cleanup', step: 'cr_cleanup_start', namespace: ctx.ns, created: ctx.created }));
  for (const name of ctx.created.konkservices) {
    safeDelete(ctx.token, u.konkservice(ctx.ns, name), 'konkservice_delete', name);
  }
  for (const name of ctx.created.etcds) {
    safeDelete(ctx.token, u.etcd(ctx.ns, name), 'etcd_delete', name);
  }
  for (const name of ctx.created.konks) {
    safeDelete(ctx.token, u.konk(ctx.ns, name), 'konk_delete', name);
  }
}

// ---------- teardown ----------
export function teardown(data) {
  if (!data || !data.ns) return;
  const ns = data.ns;
  if (!ns.startsWith('auto-test-')) {
    console.log(JSON.stringify({ phase: 'teardown', skipped: true, reason: `namespace '${ns}' missing auto-test- prefix` }));
    return;
  }
  console.log(JSON.stringify({ phase: 'teardown', step: 'namespace_delete', namespace: ns }));
  const r = kdelete(data.token, u.namespace(ns), 'namespace_delete');
  check(r, {
    'teardown: namespace delete 2xx/404': (resp) => resp.status === 200 || resp.status === 202 || resp.status === 404,
  });
  // Best-effort wait for namespace removal so residual CRs are GC'd.
  pollDeleted(data.token, u.namespace(ns), 'namespace_get_after_delete');
}
