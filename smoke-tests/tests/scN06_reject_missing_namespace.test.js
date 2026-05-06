// SC-N-06: Reject create in non-existent namespace.
import { check } from 'k6';
import { API_GROUP, API_VERSION, u } from '../config/config.js';
import { autoTestName, kpost } from '../helpers/utils.js';
import { isClientError, isCreated } from '../helpers/validators.js';

export function runSCN06(ctx) {
  const sid = 'SC-N-06';
  const ns = `auto-test-nope-${Date.now()}-${__VU}`;
  const name = autoTestName(sid, 'badns') + '-konk';
  const body = JSON.stringify({
    apiVersion: `${API_GROUP}/${API_VERSION}`,
    kind: 'Konk',
    metadata: { name, namespace: ns },
    spec: { scope: 'namespace' },
  });
  const r = kpost(ctx.token, u.konks(ns), body, 'konk_create_missing_ns');
  check(r, {
    'SC-N-06 konk_create in missing ns rejected (4xx)': isClientError,
    'SC-N-06 not persisted': (resp) => !isCreated(resp),
  });
}
