// SC-N-02: Reject KonkService missing required fields / invalid konk.name pattern.
import { check } from 'k6';
import { API_GROUP, API_VERSION, u } from '../config/config.js';
import { autoTestName, kpost } from '../helpers/utils.js';
import { isClientError, isCreated } from '../helpers/validators.js';

export function runSCN02(ctx) {
  const sid = 'SC-N-02';
  const name = autoTestName(sid, 'badks');
  const body = JSON.stringify({
    apiVersion: `${API_GROUP}/${API_VERSION}`,
    kind: 'KonkService',
    metadata: { name, namespace: ctx.ns },
    // Missing: group, service, version. konk.name violates ^.+-konk$
    spec: { konk: { name: 'not-matching-pattern' } },
  });
  const r = kpost(ctx.token, u.konkservices(ctx.ns), body, 'konkservice_create_invalid');
  check(r, {
    'SC-N-02 konkservice_create rejected (4xx)': isClientError,
    'SC-N-02 not persisted (no 2xx)': (resp) => !isCreated(resp),
  });
}
