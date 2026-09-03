# test_importexport.py — Failure Analysis (us-stg-1, 2026-08-07)

**Suite:** `e2e_automation/test/test_importexport.py`
**Cluster:** `us-stg-1`
**Run date:** 2026-08-07
**Result:** 9 FAILED / multiple PASSED

---

## Summary

| # | Test | Verdict |
|---|------|---------|
| 1 | `test_export_import_csv_with_all_data_types` | False positive — auth failure |
| 2 | `test_import_export_with_BootStrap_by_changing_esxi_ntp_mode` | False positive — bootstrap verify 500 |
| 3 | `test_import_export_with_BootStrap_by_changing_ntp_server` | False positive — bootstrap verify 500 |
| 4 | `test_import_export_with_BootStrap_by_changing_ntp_to_esxi_mode` | False positive — bootstrap verify 500 |
| 5 | `test_import_export_with_BootStrap_by_changing_mtu_values_ipv4` | False positive — bootstrap verify 500 |
| 6 | `test_import_export_with_BootStrap_by_changing_mtu_values_ipv6` | False positive — bootstrap verify 500 |
| 7 | `test_import_export_with_BootStrap_by_changing_docker_bip` | False positive — bootstrap verify 500/404 |
| 8 | `test_import_export_with_BootStrap_by_changing_default_docker_bip` | False positive — bootstrap verify 500 |
| 9 | `test_error_log` | False positive — tagging service timeout + test bug |

---

## Failure Details

### 1. `test_export_import_csv_with_all_data_types`

**Class:** `test_import_exportapi_Tagging_csv_e2e_flow`
**Duration:** 0.40s

**Error:**
```
AssertionError: Export failed with response code 401
GET /bulk/v1/export → 401 Authorization Required (nginx)
```

**Log:**
```
[Login with Identity Service: akumar@infoblox.com][POST:/v2/session/users/sign_in] >> [401]
ERROR: HTTP interceptor error: Unauthorized
```

**Root cause:** `akumar@infoblox.com` is not provisioned or has wrong credentials on us-stg-1. `get_auth_headers()` returns `None`, so the export request is made with no auth token and nginx rejects it with 401. The bulk export/import functionality was never exercised.

**Fix:** Provision `akumar@infoblox.com` on us-stg-1 or replace with a valid test user for the CSV `all_data_types` test case.

---

### 2–8. Bootstrap JSON e2e flow (7 cases)

**Class:** `test_import_exportapi_BootStrap_json_e2e_flow`
**Duration:** ~201s each (200s wait built in)

**Test cases:**
- `test_import_export_with_BootStrap_by_changing_esxi_ntp_mode`
- `test_import_export_with_BootStrap_by_changing_ntp_server`
- `test_import_export_with_BootStrap_by_changing_ntp_to_esxi_mode`
- `test_import_export_with_BootStrap_by_changing_mtu_values_ipv4`
- `test_import_export_with_BootStrap_by_changing_mtu_values_ipv6`
- `test_import_export_with_BootStrap_by_changing_docker_bip`
- `test_import_export_with_BootStrap_by_changing_default_docker_bip`

**Error:**
```
AssertionError: BootStrap import is not successful
assert False
test_importexport.py:915
```

**Log (same pattern for all 7):**
```
INFO  Export API response code: 202
INFO  Export operation status attempt 1/12: completed
INFO  Analyze API response code: 200
INFO  Import API response code: 202
INFO  Import operation status: completed
INFO  Import was successful, waiting 180 seconds for bootstrap changes to apply
INFO  Verifying bootstrap config for ophid: c6beedfe32a53116e7ed8b541c47998b
ERROR Bootstrap get request failed with 500   ← (404 in one case)
ERROR Failed to retrieve bootstrap config for ophid: c6beedfe32a53116e7ed8b541c47998b
```

**What works:** Export → download → file update → upload → analyze → import — all succeed (202/200).

**What fails:** The post-import verification step calls:
```
GET api/atlas-bootstrap-app/v1/host/c6beedfe32a53116e7ed8b541c47998b/config
→ HTTP 500 (HTTP 404 in one case)
```

**Root cause:** The only host exported from us-stg-1 is `ZTP_host-degrade-lr_785612098781592921` (ophid `c6beedfe32a53116e7ed8b541c47998b`). This is a ZTP degrade-state test host, not a real on-prem bootstrapped appliance. The bootstrap-app API has no live bootstrap config for this ophid and returns 500/404. The import/export functionality itself works correctly.

**Fix:** The bootstrap verification tests require a real on-prem host that has gone through bootstrap and has a live bootstrap-app config. Either:
- Provision a real bootstrapped host on us-stg-1, or
- Skip the `verifybootstrapimport` step when no real on-prem host is available and only assert that the import completes successfully.

---

### 9. `test_error_log`

**Duration:** 1.13s

**Error:**
```
AssertionError: Useless error: {
  'data_type': 'tagging.bulk.infoblox.com/v1alpha1/tags',
  'record': '1',
  'message': '"call to List() failed: Export error occurred: Export error occurred:
    Could not get list of tags from tagging service,
    error: Get "http://tagging.tagging-v2.svc.cluster.local:8081/v2/tags?_offset=0&_limit=100&_order_by=id":
    context deadline exceeded (Client.Timeout exceeded while awaiting headers)"',
  'timestamp': '2026-08-05T13:14:27.966649Z'
}
```

**Root cause (two parts):**

**Part A — Real infrastructure issue (tagging-v2 memory pressure):**

On 2026-08-05T13:14:27Z, the `bulk` service timed out trying to reach `tagging.tagging-v2.svc.cluster.local:8081/v2/tags`. "Client.Timeout exceeded while awaiting headers" means the TCP connection was accepted but the tagging service never sent HTTP response headers within the client timeout.

Cluster state confirmed as ongoing:
- `tagging-v2` HPA maxed out: **5/5 replicas**, memory at **77–80% / 80% threshold** — cannot scale further
- Each pod uses ~325–351 Mi of 500 Mi limit; GC pressure under export load causes response stalls
- `bulk` pod was **OOMKilled** today at 15:02:49 IST — bulk itself also memory-constrained

**Full error inventory from `/bulk/v1/operation` (queried 2026-08-12):**

| Count | data_type | Message pattern |
|------:|-----------|-----------------|
| 7,576 | `tagging.bulk.infoblox.com/v1alpha1/values` | `'spec' section must contain a non-empty 'id' field` |
| 247 | `tagging.bulk.infoblox.com/v1alpha1/values` | `'name' field from 'metadata' section must match the field from the 'spec' section defined as a key: matadata.name = <tag_id>_<value_id>, spec.<key> = <value_id>` |
| 1 | `tagging.bulk.infoblox.com/v1alpha1/tags` | `context deadline exceeded (Client.Timeout exceeded while awaiting headers)` ← **this is what triggered the test failure** |
| 1 | `tagging.bulk.infoblox.com/v1alpha1/tags` | `the server was unable to return a response in the time allotted, but may still be processing the request` |

The 7,576 + 247 `values` errors are **pre-existing import validation errors** — they indicate that some tag value records in the system have either an empty `id` in their spec or a mismatch between `metadata.name` and the spec key field. The name mismatch messages also contain a typo (`matadata` instead of `metadata`) which is a bug in the bulk service error text. These validation errors are not related to the tagging service timeout but would also cause `test_error_log` to fail since the test's classification logic doesn't handle them either.

**Part B — Test logic bug:**

The test has a broken `or` condition that silently skips the "object does not exist" check:

```python
# BUG: Python evaluates ("A" or "B") as "A" — "object does not exist" is never checked
if ("unable to return a response" or "object does not exist") in error["message"]:
    pass
elif error["data_type"].lower()[:-2] in error["message"].lower():
    # Checks if "tagging.bulk.infoblox.com/v1alpha1/tag" (without trailing 's')
    # appears verbatim in the message — it doesn't, even though the error is clearly
    # about the tagging service
    pass
else:
    assert False, f"Useless error: {error}"
```

None of the 7,825 errors in the ops log match either branch, so the test will always fail as long as any of these errors exist in the database.

**Fix (both parts required):**

1. **Infrastructure:** Raise the `tagging-v2` memory limit above 500 Mi and/or increase HPA `maxReplicas` above 5 to allow the service to handle concurrent export load without GC stalls.

2. **Validation errors:** Investigate why 7,576 tag value records are missing the `id` field and why 247 have a `metadata.name`/`spec.key` mismatch. These may be orphaned records from previous test runs that need cleanup.

3. **Test:** Fix the error classification logic to handle the actual error patterns present:
```python
skip_patterns = (
    "unable to return a response",
    "object does not exist",
    "context deadline exceeded",
    "spec' section must contain a non-empty",
    "name' field from 'metadata' section must match",
)
if any(p in error["message"] for p in skip_patterns):
    pass
elif error["data_type"].lower()[:-2] in error["message"].lower():
    pass
else:
    assert False, f"Useless error: {error}"
```

---

## Cluster Issues Found During Investigation

| Issue | Namespace | Details | Severity |
|-------|-----------|---------|----------|
| tagging-v2 at max replicas + near memory ceiling | `tagging-v2` | 5/5 replicas, 77–80% memory, 500Mi limit | High |
| bulk pod OOMKilled | `aggregate` | OOMKilled at 15:02:49 IST today, restarted once | High |
| konk readiness probe flapping | `tagging-v2` | Pod `tagging-aggregate-api-apiservice-konk-service-kubectl-apis75scr`: 467 failures over 14h | Medium |
| Ingress sync error (metacontroller) | `tagging-v2` | `tagging-v2-ingress`: "resourceVersion should not be set on objects to be created" — 82 occurrences over 11h | Medium |
| Kafka topic replica reassignment | `tagging-v2` | `captured-events-stg-1.tagging-dapr-component.dapr-x.io`: "failed to update topic: replica reassignment unsupported" | Low |
