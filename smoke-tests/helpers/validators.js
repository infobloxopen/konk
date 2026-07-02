// Reusable validation helpers used inside k6 check().
import { parseBody } from './utils.js';

// ---- Status validators ----
export const isOk = (r) => r.status === 200;
export const isCreated = (r) => r.status === 200 || r.status === 201;
export const isAccepted = (r) => r.status === 200 || r.status === 202;
export const isNotFound = (r) => r.status === 404;
export const isUnauthorized = (r) => r.status === 401;
export const isForbidden = (r) => r.status === 403;
export const isClientError = (r) => r.status >= 400 && r.status < 500;
export const isInvalid = (r) => r.status === 400 || r.status === 422;

// ---- Common body validators ----
// For Kubernetes objects: id == metadata.uid
export const hasId = (r) => {
  const b = parseBody(r);
  const uid = b && b.metadata && b.metadata.uid;
  return typeof uid === 'string' && uid.length > 0;
};
// For Kubernetes lists: items array
export const hasResultsArray = (r) => Array.isArray(parseBody(r).items);

export const hasNoError = (r) => {
  const b = parseBody(r);
  // Kubernetes errors come as kind=Status,status=Failure
  return !(b && b.kind === 'Status' && b.status === 'Failure');
};

export const bodyFieldEquals = (field, expected) => (r) => parseBody(r)[field] === expected;
export const metadataFieldEquals = (field, expected) => (r) =>
  ((parseBody(r).metadata) || {})[field] === expected;

export const hasAllowedBoolean = (r) => typeof parseBody(r).allowed === 'boolean';

export const isPromExposition = (r) =>
  typeof r.body === 'string' && (/^# HELP /m.test(r.body) || /^# TYPE /m.test(r.body));
