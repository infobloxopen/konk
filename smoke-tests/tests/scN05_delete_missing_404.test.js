// SC-N-05: DELETE non-existent resource returns 404.
import { check } from 'k6';
import { u } from '../config/config.js';
import { autoTestName, kdelete } from '../helpers/utils.js';
import { isNotFound } from '../helpers/validators.js';

export function runSCN05(ctx) {
  const sid = 'SC-N-05';
  const k = autoTestName(sid, 'del-missing') + '-konk';
  const r = kdelete(ctx.token, u.konk(ctx.ns, k), 'konk_delete_missing');
  check(r, { 'SC-N-05 konk_delete missing 404': isNotFound });
}
