// SC-01: Konk CR full lifecycle (create -> get -> list -> patch -> status -> delete)
import { check } from 'k6';
import { API_GROUP, API_VERSION, u } from '../config/config.js';
import { autoTestName, kpost, kget, kpatch, parseBody, pollDeployed } from '../helpers/utils.js';
import { isCreated, isOk, hasId, hasNoError, hasResultsArray, metadataFieldEquals } from '../helpers/validators.js';
import { ensureAutoTest, resourceExists } from '../helpers/resourceHelpers.js';

export function runSC01(ctx) {
  const sid = 'SC-01';
  // Konk name must end in '-konk' to satisfy the KonkService konk.name regex if reused.
  const name = autoTestName(sid, 'konk') + '-konk';
  const body = JSON.stringify({
    apiVersion: `${API_GROUP}/${API_VERSION}`,
    kind: 'Konk',
    metadata: { name, namespace: ctx.ns, labels: { 'auto-test': 'true' } },
    spec: { scope: 'namespace' },
  });

  // CREATE
  const c = kpost(ctx.token, u.konks(ctx.ns), body, 'konk_create');
  check(c, {
    'SC-01 konk_create 201': isCreated,
    'SC-01 konk_create has uid': hasId,
    'SC-01 konk_create no error': hasNoError,
    'SC-01 konk_create name matches': metadataFieldEquals('name', name),
  });
  if (!isCreated(c)) return;
  ctx.created.konks.push(name);

  // GET
  const g = kget(ctx.token, u.konk(ctx.ns, name), 'konk_get');
  check(g, {
    'SC-01 konk_get 200': isOk,
    'SC-01 konk_get exists': (r) => resourceExists(r, 'name', name),
  });

  // LIST
  const l = kget(ctx.token, u.konks(ctx.ns), 'konk_list');
  check(l, {
    'SC-01 konk_list 200': isOk,
    'SC-01 konk_list items[]': hasResultsArray,
  });

  // PATCH
  ensureAutoTest(name, 'PATCH', 'konk_patch');
  const patchBody = JSON.stringify({ metadata: { labels: { 'auto-test-patched': 'true' } } });
  const p = kpatch(ctx.token, u.konk(ctx.ns, name), patchBody, 'konk_patch');
  check(p, { 'SC-01 konk_patch 200': isOk });

  // STATUS poll (Deployed=True, reason ~ /^(Install|Upgrade)?Successful$/)
  const polled = pollDeployed(ctx.token, u.konk(ctx.ns, name), 'konk_status_get');
  check(polled, {
    'SC-01 konk reaches Deployed=True with Successful reason': (x) => x.ok === true,
  });
}
