// SC-02: KonkService CR full lifecycle. Creates its own parent Konk per plan.
import { check } from 'k6';
import { API_GROUP, API_VERSION, u } from '../config/config.js';
import { autoTestName, kpost, kget, kpatch, pollDeployed } from '../helpers/utils.js';
import { isCreated, isOk, hasId, hasResultsArray, metadataFieldEquals } from '../helpers/validators.js';
import { ensureAutoTest } from '../helpers/resourceHelpers.js';

export function runSC02(ctx) {
  const sid = 'SC-02';

  // Parent Konk
  const konkName = autoTestName(sid, 'parent') + '-konk';
  const konkBody = JSON.stringify({
    apiVersion: `${API_GROUP}/${API_VERSION}`,
    kind: 'Konk',
    metadata: { name: konkName, namespace: ctx.ns, labels: { 'auto-test': 'true' } },
    spec: { scope: 'namespace' },
  });
  const k = kpost(ctx.token, u.konks(ctx.ns), konkBody, 'konk_create');
  check(k, { 'SC-02 parent konk_create 201': isCreated });
  if (!isCreated(k)) return;
  ctx.created.konks.push(konkName);

  // KonkService
  const ksName = autoTestName(sid, 'ks');
  const ksBody = JSON.stringify({
    apiVersion: `${API_GROUP}/${API_VERSION}`,
    kind: 'KonkService',
    metadata: { name: ksName, namespace: ctx.ns, labels: { 'auto-test': 'true' } },
    spec: {
      group: {
        name: 'auto-test.example.com',
        kinds: ['AutoTestThing'],
        verbs: ['create', 'get', 'list', 'delete'],
      },
      konk: { name: konkName },
      service: { name: ksName },
      version: 'v1alpha1',
    },
  });
  const c = kpost(ctx.token, u.konkservices(ctx.ns), ksBody, 'konkservice_create');
  check(c, {
    'SC-02 konkservice_create 201': isCreated,
    'SC-02 konkservice_create has uid': hasId,
  });
  if (!isCreated(c)) return;
  ctx.created.konkservices.push(ksName);

  // GET
  const g = kget(ctx.token, u.konkservice(ctx.ns, ksName), 'konkservice_get');
  check(g, {
    'SC-02 konkservice_get 200': isOk,
    'SC-02 konkservice_get name matches': metadataFieldEquals('name', ksName),
  });

  // LIST
  const l = kget(ctx.token, u.konkservices(ctx.ns), 'konkservice_list');
  check(l, {
    'SC-02 konkservice_list 200': isOk,
    'SC-02 konkservice_list items[]': hasResultsArray,
  });

  // PATCH (label only)
  ensureAutoTest(ksName, 'PATCH', 'konkservice_patch');
  const patchBody = JSON.stringify({ metadata: { labels: { 'auto-test-patched': 'true' } } });
  const p = kpatch(ctx.token, u.konkservice(ctx.ns, ksName), patchBody, 'konkservice_patch');
  check(p, { 'SC-02 konkservice_patch 200': isOk });

  // STATUS poll
  const polled = pollDeployed(ctx.token, u.konkservice(ctx.ns, ksName), 'konkservice_status_get');
  check(polled, {
    'SC-02 konkservice reaches Deployed=True with Successful reason': (x) => x.ok === true,
  });
}
