# Smoke Test Failure: SMOKE-TAG-002 (List Tags) — 503 via KONK

**Date:** 2026-05-18  
**Updated:** 2026-05-19  
**Investigator:** Rahul Satal  
**Status:**
- **us-dev-2: RESOLVED** — fixed image `v0.1.5-39-g5307097-j62` deployed, all 16 tests pass
- **us-dev-5: RESOLVED** — newer image `v0.1.5-40-g74b524e-j63` already deployed, all 16 tests pass
- Issue 2 (KONK rollout restart): PENDING

## Summary

The 4 failing checks in SMOKE-TAG-002 are caused by **two separate issues**:

1. **PRIMARY (causes the 503):** A panic in `tagging-aggregate-api` at `pkg/storage/tag.go:230` — `runtime error: makeslice: cap out of range`. The list handler crashes, killing the HTTP/2 stream, which KONK reports as `503 stream error: INTERNAL_ERROR`.  
   **Status: FIXED** — PR #83 merged.

2. **SECONDARY (separate issue):** The konk-service kubeconfig certificate has a 12-hour duration, and the tagging-aggregate-api pod doesn't hot-reload it. This causes `Unauthorized` errors for delegated auth ConfigMap watches, but is NOT the direct cause of the 503.  
   **Status: PENDING** — rollout restart implementation needed in KONK repo.

## Affected Environments

- **us-dev-2** (confirmed — makeslice panic, 503 on list, fix deployed and verified)
- **us-dev-5** (NO production issue — test failure was caused by using wrong cert locally)
- Likely all environments running `v0.1.5-38-g3fed57b` or later had the latent panic bug (Issue 1)

### us-dev-5: False Alarm (Testing Error)

**UPDATE 2026-05-19:** us-dev-5 never had a production issue. The 50% smoke test failure (9/18) was caused by a **local testing error** — we used the wrong TLS certificate.

**What went wrong during testing:**
1. When setting up local certs for us-dev-5, we extracted the cert from `bulk-konk-kubeconfig` secret (contains `CN=kubernetes-admin`, signed by kubeadm CA `CN=kubernetes`)
2. Smoke tests authenticate via the **front-proxy pattern**, which requires the proxy-client cert from `bulk-konk-proxy-client` secret (contains `CN=core`, signed by requestheader CA `CN=konk.infoblox`)
3. These are **two completely separate CA chains** in KONK by design — using one where the other is expected causes auth failures
4. Once we extracted the correct cert from `bulk-konk-proxy-client`, all 16 tests passed immediately

**Key facts:**
- us-dev-5 was already running `v0.1.5-40-g74b524e-j63` (newer than the fix) — no makeslice panic
- No deployment change, restart, or PR was needed for us-dev-5
- The service was working correctly the entire time

**Lesson:** KONK has two CAs — always use `bulk-konk-proxy-client` secret for smoke test certs, never the kubeconfig secret.

The earlier "503: service unavailable" errors in KONK logs for `redirect.bulk` and `atcapi.bulk` are separate issues for those services (not tagging-related).

## Symptoms

- **4 smoke test failures** in `SMOKE-TAG-002: List Tags`
- KONK returns `503: error trying to reach service: stream error: stream ID N; INTERNAL_ERROR; received from peer`
- Restarting the tagging-aggregate-api pod does NOT fix it (panic is deterministic)
- `tagging-aggregate-api` logs show: `panic: runtime error: makeslice: cap out of range` on `GET /tags`
- Adding `?limit=500` (or any explicit limit) to the request works around the panic

## Smoke Test Results

### Before fix (no `?limit=`):
```
Scenarios: 15 passed, 1 failed, 0 skipped
Checks:    51 passed, 4 failed
Result:    FAIL ✗
```

### After fix (with `?limit=500` workaround in smoke test):
```
Scenarios: 16 passed, 0 failed, 0 skipped
Checks:    55 passed, 0 failed
Result:    PASS ✓
```

This confirms the panic only triggers when no limit is specified and `MaxUint64` flows through to `makeslice`.

### After deploying fixed image (`v0.1.5-39-g5307097-j62`) — NO `?limit=` workaround needed:
```
Scenarios: 16 passed, 0 failed, 0 skipped
Checks:    55 passed, 0 failed
Result:    PASS ✓
```

Verified in us-dev-2 on 2026-05-18: manually updated deployment image from `v0.1.5-38-g3fed57b-j61` → `v0.1.5-39-g5307097-j62`, smoke tests pass with bare `GET /tags` (no limit parameter).

---

## Issue 1: Panic in tagging-aggregate-api (PRIMARY — FIXED)

### Location

- `pkg/storage/tag.go:230` — `tags := make([]*taggingpb.Tag, 0, limit)`
- `pkg/storage/value.go:225` — `values := make([]*taggingpb.Value, 0, limit)` (same pattern)

### Root Cause

The `limit` variable computation (lines 211-220 in tag.go):

```go
limit = func() int {
    if i, err := strconv.Atoi(strconv.FormatUint(o.Limit, 10)); err != nil {
        klog.V(5).Infof("Limit overflows max int value: %s", o.Limit)
        return math.MaxInt  // ← BUG: causes panic
    } else if i == 0 {
        return 100
    } else {
        return i
    }
}()
```

When `o.Limit` is a uint64 value > `math.MaxInt64` (2^63-1), `strconv.Atoi` returns an error, and the code falls back to `math.MaxInt` (9223372036854775807). Then `make([]*taggingpb.Tag, 0, math.MaxInt)` panics because you can't allocate a slice with that capacity.

### Why this started happening now (latent bug)

This bug was latent — two incompatible changes from different years were never deployed together until the distroless merge:

| Commit | Date | Change | Effect |
|--------|------|--------|--------|
| `a055736` | 2021-05 | atlas-controller-runtime sets `options.Limit = MaxUint64` when no `?limit=` query param | Sends massive uint64 to storage |
| `2a59548` | 2022-04 | Chunk/pagination code added `math.MaxInt` fallback on uint64→int overflow | Panic when `make()` receives this value |
| `3fed57b` | 2026-04 | Distroless merge deployed both together for the first time | Panic triggered in production |

The trigger path:
1. Client sends `GET /tags` (no `?limit=` parameter)
2. `k8s.io/apiserver` passes `opts.Predicate.Limit = 0` to the store
3. `atlas-controller-runtime/pkg/apiservice/storage/store.go` (line 396): `if options.Limit == 0 { options.Limit = apis.MaxUint64 }`
4. `tag.go` receives `o.Limit = 18446744073709551615` (MaxUint64)
5. `strconv.FormatUint` → `"18446744073709551615"` → `strconv.Atoi` fails (overflows int)
6. Fallback returns `math.MaxInt` → `make([]*taggingpb.Tag, 0, 9223372036854775807)` → **PANIC**

### Stack Trace

```
github.com/Infoblox-CTO/atlas.tagging.aggregateapi/pkg/storage.(*TagStore).Range
  → pkg/storage/tag.go:230
github.com/Infoblox-CTO/atlas-controller-runtime/pkg/apiservice/storage/backend/wrappers.(*AdapterBackend).Range
github.com/Infoblox-CTO/atlas-controller-runtime/pkg/apiservice/storage.(*store).List
k8s.io/apiserver/pkg/registry/generic/registry.(*Store).ListPredicate
k8s.io/apiserver/pkg/registry/generic/registry.(*Store).List
k8s.io/apiserver/pkg/endpoints/handlers.ListResource
```

### Fix Applied

**PR:** https://github.com/Infoblox-CTO/atlas.tagging.aggregateapi/pull/83  
**Branch:** `fix/list-tags-panic-makeslice`  
**Commit:** `d5d51a2`

Changed `return math.MaxInt` to `return 100` in both files:

```go
// tag.go (line 214) and value.go (line 225)
limit = func() int {
    if i, err := strconv.Atoi(strconv.FormatUint(o.Limit, 10)); err != nil {
        klog.V(5).Infof("Limit overflows max int value: %d", o.Limit)
        return 100  // ← FIXED: was math.MaxInt
    } else if i == 0 {
        return 100
    } else {
        return i
    }
}()
```

Also removed unused `"math"` import from both files.

---

## Issue 2: 12-Hour Kubeconfig Certificate (SECONDARY — PENDING)

### Mechanism

1. cert-manager issues a 12h client certificate for the kubeconfig
2. `konk-service reconcile-kubeconfig` (runs every ~3 min) reads the rotated cert, rebuilds the kubeconfig, and updates the Kubernetes Secret (`*-konk-service-kubeconfig`)
3. `tagging-aggregate-api` pod mounts this secret and passes it via:
   - `--authentication-kubeconfig=/kubeconfig/admin.conf`
   - `--authorization-kubeconfig=/kubeconfig/admin.conf`
4. The Go apiserver library (`k8s.io/apiserver`) **caches the client TLS certificate in memory** and does NOT reload from disk when the file changes
5. After 12 hours, the in-memory cert expires → all requests from `tagging-aggregate-api` to KONK get `Unauthorized`
6. KONK's aggregation layer can't reach the backend → returns `503`

### Evidence (us-dev-2, 2026-05-18):

| Signal | Value |
|--------|-------|
| KONK pod age | 20 min (recently restarted) |
| tagging-aggregate-api pod age | 11 days |
| Kubeconfig secret cert validity | May 18 08:07 → May 18 20:07 (12h) |
| Expired cert dates in KONK logs | May 7, 8, 9, 13, 15, 17 (multiple rotations missed) |
| Certificate expiry error count (500 log lines) | 222 |

### Why individual operations still work:

- GET/POST/PUT/DELETE for individual resources use KONK's **front-proxy** path. The request goes: client → KONK kube-apiserver → aggregated backend. KONK authenticates the client using `bulk-konk-proxy-client` cert (valid until Jul 2026).
- **List** operations trigger the `available_controller` which health-checks the backend via its own kubeconfig credentials — those are the ones that expire.

### Fix (KONK repo): Trigger pod rollout on cert rotation

**Chosen approach:** Option 2 — annotate dependent deployments with cert checksum on change.

Update `cmd/konk-service/reconcile_kubeconfig.go`: when `certSum != *lastCertSum` (cert has rotated), patch dependent deployments with an annotation like `konk.infoblox.com/cert-checksum: <sha256>` to trigger a rolling restart.

**Rejected:** Option 1 (increase cert duration to 1 year) — security risk.

**Implementation location:** `cmd/konk-service/reconcile_kubeconfig.go` around line ~200 where `if certSum != *lastCertSum` is checked.

## Immediate Workaround

### For Issue 1 (panic):
Add `?limit=500` to list requests until PR #83 is deployed:
```
GET /apis/tagging.bulk.infoblox.com/v1alpha1/namespaces/default/tags?limit=500
```

### For Issue 2 (cert expiry):
Restart the `tagging-aggregate-api` pod to pick up the latest kubeconfig cert:
```bash
kubectl rollout restart deployment tagging-aggregate-api -n tagging-v2
```

Note: This only fixes the cert expiry issue temporarily (12h window). The panic on list (Issue 1) persists regardless of restart.

## Related Files

### atlas.tagging.aggregateapi repo
- `pkg/storage/tag.go:211-230` — limit computation + makeslice (FIXED)
- `pkg/storage/value.go:210-225` — same pattern (FIXED)
- `vendor/github.com/Infoblox-CTO/atlas-controller-runtime/pkg/apiservice/storage/store.go:391-398` — where MaxUint64 is set

### KONK repo
- `helm-charts/konk-service/templates/kubeconfig-certificate.yaml` — cert duration (12h)
- `cmd/konk-service/reconcile_kubeconfig.go` — kubeconfig reconciliation loop (needs rollout restart)
- `helm-charts/konk-service/templates/kubeconfig-deployment.yaml` — reconciler deployment

## Timeline

| Date | Event |
|------|-------|
| 2021-05 | `a055736`: atlas-controller-runtime adds `MaxUint64` default for limit |
| 2022-04 | `2a59548`: chunk code adds `math.MaxInt` overflow fallback |
| 2026-04 | `3fed57b`: Distroless merge deploys both together → latent bug activated |
| 2026-05-18 | Investigation: root cause identified, PR #83 created and merged |
| 2026-05-18 | Fix verified in production: deployed `v0.1.5-39-g5307097-j62` to us-dev-2, all 16 smoke tests pass without `?limit=` |
| 2026-05-19 | us-dev-5: confirmed NO production issue — test failures were due to using wrong cert (kubeconfig cert instead of proxy-client cert). Already on `v0.1.5-40-g74b524e-j63`, all 16 tests pass with correct cert |
| TBD | KONK rollout restart implementation |
