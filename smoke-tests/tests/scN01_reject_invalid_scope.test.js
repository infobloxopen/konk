// SC-N-01: Reject Konk create with invalid spec.scope.
import { check } from 'k6';
import { API_GROUP, API_VERSION, u } from '../config/config.js';
import { autoTestName, kpost, kget } from '../helpers/utils.js';
import { isClientError, isCreated, isNotFound } from '../helpers/validators.js';

export function runSCN01(ctx) {
  const sid = 'SC-N-01';
  const name = autoTestName(sid, 'badscope') + '-konk';
  const body = JSON.stringify({
    apiVersion: `${API_GROUP}/${API_VERSION}`,
    kind: 'Konk',
    metadata: { name, namespace: ctx.ns },
    spec: { scope: 'invalid-scope-value' },
  });
  const r = kpost(ctx.token, u.konks(ctx.ns), body, 'konk_create_invalid_scope');
  check(r, {
    'SC-N-01 konk_create rejected (4xx)': isClientError,
    'SC-N-01 not persisted (no 2xx)': (resp) => !isCreated(resp),
  });
  const g = kget(ctx.token, u.konk(ctx.ns, name), 'konk_get_after_invalid');
  check(g, { 'SC-N-01 follow-up GET 404': isNotFound });
}
