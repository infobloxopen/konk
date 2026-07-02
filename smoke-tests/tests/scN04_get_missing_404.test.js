// SC-N-04: GET non-existent resources returns 404.
import { check } from 'k6';
import { u } from '../config/config.js';
import { autoTestName, kget } from '../helpers/utils.js';
import { isNotFound } from '../helpers/validators.js';

export function runSCN04(ctx) {
  const sid = 'SC-N-04';
  const k = autoTestName(sid, 'missing') + '-konk';
  const ks = autoTestName(sid, 'missing-ks');
  const e = autoTestName(sid, 'missing-etcd');

  const r1 = kget(ctx.token, u.konk(ctx.ns, k), 'konk_get_missing');
  check(r1, { 'SC-N-04 konk_get missing 404': isNotFound });

  const r2 = kget(ctx.token, u.konkservice(ctx.ns, ks), 'konkservice_get_missing');
  check(r2, { 'SC-N-04 konkservice_get missing 404': isNotFound });

  const r3 = kget(ctx.token, u.etcd(ctx.ns, e), 'etcd_get_missing');
  check(r3, { 'SC-N-04 etcd_get missing 404': isNotFound });
}
