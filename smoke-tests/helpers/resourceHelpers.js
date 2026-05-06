// Resource lifecycle and AUTO_TEST_ guard helpers.
import { fail, check } from 'k6';
import { parseBody, kdelete, logRequest } from './utils.js';

// AUTO_TEST guard. K8s names must be RFC1123 lowercase, so the prefix is the
// equivalent lowercased form 'auto-test-'.
export const AUTO_TEST_PREFIX = 'auto-test-';

export const isAutoTestResource = (value) =>
  typeof value === 'string' && value.startsWith(AUTO_TEST_PREFIX);

// Hard guard: refuse to mutate non-AUTO_TEST resources.
export function ensureAutoTest(name, op, endpointName) {
  if (!isAutoTestResource(name)) {
    fail(
      `GUARDRAIL VIOLATION: refusing ${op} on '${name}' for endpoint '${endpointName}'. ` +
        `Only resources prefixed '${AUTO_TEST_PREFIX}' may be mutated.`,
    );
  }
}

// Post-create / get validators
export const resourceExists = (getResponse, idField, expectedId) =>
  ((parseBody(getResponse).metadata) || {})[idField] === expectedId;

export const resourceDeleted = (getResponse) =>
  getResponse.status === 404 || (parseBody(getResponse).items || []).length === 0;

// Safe delete that respects the AUTO_TEST_ guard. Used in cleanup.
export function safeDelete(token, url, endpointName, name) {
  if (!isAutoTestResource(name)) {
    console.log(
      JSON.stringify({
        phase: 'cleanup',
        endpoint: endpointName,
        skipped: true,
        reason: `name '${name}' missing ${AUTO_TEST_PREFIX} prefix`,
      }),
    );
    return null;
  }
  const r = kdelete(token, url, endpointName);
  check(r, {
    [`${endpointName} delete 2xx/404`]: (resp) =>
      resp.status === 200 || resp.status === 202 || resp.status === 404,
  });
  return r;
}
