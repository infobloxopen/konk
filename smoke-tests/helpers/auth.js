// Authentication helpers.
// Kubernetes-bearer-token mode is the default for konk (per smoke-test-plan
// authentication_strategy). The two-step JWT flow defined in the prompt
// (POST /v2/session/users/sign_in) is supported when AUTH_MODE=jwt.

import http from 'k6/http';
import { fail } from 'k6';
import {
  AUTH_MODE,
  KUBE_BEARER_TOKEN,
  KUBE_USE_PROXY,
  BASE_URL,
  USER_EMAIL,
  USER_PASSWORD,
} from '../config/config.js';
import { logRequest, parseBody } from './utils.js';

export function jwtSignIn() {
  if (!BASE_URL || !USER_EMAIL || !USER_PASSWORD) {
    fail('AUTH_MODE=jwt requires BASE_URL, USER_EMAIL, USER_PASSWORD');
  }
  const url = `${BASE_URL}/v2/session/users/sign_in`;
  const payload = JSON.stringify({ email: USER_EMAIL, password: USER_PASSWORD });
  const resp = http.post(url, payload, {
    headers: { 'Content-Type': 'application/json' },
    timeout: '30s',
  });
  logRequest('setup', 'jwt_sign_in', 'POST', url, { email: USER_EMAIL, password: '***' }, resp);
  if (resp.status < 200 || resp.status >= 300) {
    fail(`JWT sign-in failed: status=${resp.status}`);
  }
  const b = parseBody(resp);
  const token = b.access_token || b.token || b.jwt;
  if (!token) fail('JWT sign-in response missing access_token/token/jwt');
  return token;
}

// Returns the bearer token to use for kube-apiserver calls.
export function authToken() {
  if (AUTH_MODE === 'jwt') return jwtSignIn();
  // When using `kubectl proxy`, identity comes from kubeconfig, not a token.
  if (KUBE_USE_PROXY) return '';
  if (!KUBE_BEARER_TOKEN) {
    fail('KUBE_BEARER_TOKEN is required when AUTH_MODE=kube (default). Set KUBE_USE_PROXY=true if going through `kubectl proxy`.');
  }
  return KUBE_BEARER_TOKEN;
}
