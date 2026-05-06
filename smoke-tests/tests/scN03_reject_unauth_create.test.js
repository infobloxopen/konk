// SC-N-03: Unauthenticated create rejected.
import http from 'k6/http';
import { check } from 'k6';
import { API_GROUP, API_VERSION, u, KUBE_INSECURE_SKIP_TLS_VERIFY, KUBE_USE_PROXY } from '../config/config.js';
import { autoTestName, logRequest, logSkip, safeBody } from '../helpers/utils.js';
import { isUnauthorized, isForbidden, isClientError } from '../helpers/validators.js';

function postNoAuth(url, body, endpointName) {
  const r = http.post(url, body, {
    headers: { 'Content-Type': 'application/json' },
    timeout: '30s',
    insecureSkipTLSVerify: KUBE_INSECURE_SKIP_TLS_VERIFY,
  });
  logRequest('execution', endpointName, 'POST', url, safeBody(body), r);
  return r;
}

export function runSCN03(ctx) {
  const sid = 'SC-N-03';
  if (KUBE_USE_PROXY) {
    logSkip(sid, 'kube_create_unauth', 'KUBE_USE_PROXY=true: kubectl proxy injects kubeconfig identity, so unauthenticated requests cannot be exercised through it');
    return;
  }
  // Konk
  const konkName = autoTestName(sid, 'noauth') + '-konk';
  const konkBody = JSON.stringify({
    apiVersion: `${API_GROUP}/${API_VERSION}`,
    kind: 'Konk',
    metadata: { name: konkName, namespace: ctx.ns },
    spec: { scope: 'namespace' },
  });
  const r1 = postNoAuth(u.konks(ctx.ns), konkBody, 'konk_create_unauth');
  check(r1, {
    'SC-N-03 konk_create unauth rejected': (r) => isUnauthorized(r) || isForbidden(r) || isClientError(r),
  });

  // KonkService
  const ksName = autoTestName(sid, 'noauth-ks');
  const ksBody = JSON.stringify({
    apiVersion: `${API_GROUP}/${API_VERSION}`,
    kind: 'KonkService',
    metadata: { name: ksName, namespace: ctx.ns },
    spec: {
      group: { name: 'auto-test.example.com', kinds: ['X'], verbs: ['get'] },
      konk: { name: 'auto-test-noop-konk' },
      service: { name: ksName },
      version: 'v1alpha1',
    },
  });
  const r2 = postNoAuth(u.konkservices(ctx.ns), ksBody, 'konkservice_create_unauth');
  check(r2, {
    'SC-N-03 konkservice_create unauth rejected': (r) => isUnauthorized(r) || isForbidden(r) || isClientError(r),
  });

  // Etcd
  const etcdName = autoTestName(sid, 'noauth-etcd');
  const etcdBody = JSON.stringify({
    apiVersion: `${API_GROUP}/${API_VERSION}`,
    kind: 'Etcd',
    metadata: { name: etcdName, namespace: ctx.ns },
    spec: {},
  });
  const r3 = postNoAuth(u.etcds(ctx.ns), etcdBody, 'etcd_create_unauth');
  check(r3, {
    'SC-N-03 etcd_create unauth rejected': (r) => isUnauthorized(r) || isForbidden(r) || isClientError(r),
  });
}
