// SC-03: Etcd CR create/get/list/delete (delete handled in teardown).
import { check } from 'k6';
import { API_GROUP, API_VERSION, u } from '../config/config.js';
import { autoTestName, kpost, kget } from '../helpers/utils.js';
import { isCreated, isOk, hasId, hasResultsArray } from '../helpers/validators.js';

export function runSC03(ctx) {
  const sid = 'SC-03';
  const name = autoTestName(sid, 'etcd');
  const body = JSON.stringify({
    apiVersion: `${API_GROUP}/${API_VERSION}`,
    kind: 'Etcd',
    metadata: { name, namespace: ctx.ns, labels: { 'auto-test': 'true' } },
    // Minimal-but-realistic spec mirroring bulk-konk-etcd in us-dev-5.
    spec: {
      statefulset: { replicaCount: 1 },
      resources: { limits: { memory: '1Gi' } },
    },
  });

  const c = kpost(ctx.token, u.etcds(ctx.ns), body, 'etcd_create');
  check(c, {
    'SC-03 etcd_create 201': isCreated,
    'SC-03 etcd_create has uid': hasId,
  });
  if (!isCreated(c)) return;
  ctx.created.etcds.push(name);

  const g = kget(ctx.token, u.etcd(ctx.ns, name), 'etcd_get');
  check(g, { 'SC-03 etcd_get 200': isOk });

  const l = kget(ctx.token, u.etcds(ctx.ns), 'etcd_list');
  check(l, {
    'SC-03 etcd_list 200': isOk,
    'SC-03 etcd_list items[]': hasResultsArray,
  });
}
