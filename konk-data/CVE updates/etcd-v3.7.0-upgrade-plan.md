# etcd v3.7.0 Upgrade Plan — Fix CVE-2026-39821

**Date:** 2026-07-10  
**Reason:** etcd v3.6.13 (current) still contains CVE-2026-39821 (`golang.org/x/net` at v0.54.0, needs ≥ v0.55.0). etcd v3.7.0 ships with `golang.org/x/net v0.55.0` and fixes this last remaining CVE.

---

## CVE Being Fixed

| CVE | Package | v3.6.13 version | Fix requires | Severity |
|-----|---------|----------------|--------------|----------|
| CVE-2026-39821 | `golang.org/x/net` | 0.54.0 | ≥ 0.55.0 | Critical (9.6) |

---

## Compatibility Assessment

Verified the konk chart has **no blockers** for v3.7.0:

| Check | Result |
|-------|--------|
| `--experimental-*` flags used | None found |
| etcd v2 API usage | None found |
| Arch-specific image tags (`-amd64`, `-arm64`) | None found |
| Startup config method | Stable `ETCD_*` env vars only |
| Storage schema changes in v3.7 | Empty — no data migration needed |
| Rolling upgrade supported | Yes (requires cluster members at ≥ v3.6.11 first) |
| Image available on GCR | Confirmed: `gcr.io/etcd-development/etcd:v3.7.0` |

---

## Files to Update

Same 5 files updated in the previous v3.6.9 → v3.6.13 bump:

| File | Current | Target |
|------|---------|--------|
| `helm-charts/etcd/values.yaml` line 15 | `tag: "v3.6.13"` | `tag: "v3.7.0"` |
| `helm-charts/etcd/Chart.yaml` line 5 | `appVersion: "3.6.13"` | `appVersion: "3.7.0"` |
| `helm-charts/konk/values.yaml` line 63 | `tag: "v3.6.13"` | `tag: "v3.7.0"` |
| `helm-charts/konk/README.md` line 42 | `"v3.6.13"` | `"v3.7.0"` |
| `Makefile` line 18 | `ETCD_VERSION ?= v3.6.13` | `ETCD_VERSION ?= v3.7.0` |

---

## Implementation Steps

1. Edit the 5 files above (single-line version bump each)
2. Commit on branch `release/cve-remediations-july26`
3. Push to remote
4. Run Wiz scan to verify all 11 CVEs are cleared:
   ```
   wiz-scan.zsh gcr.io/etcd-development/etcd:v3.7.0
   ```
5. Update `etcd-cve-changes.md` in this folder to reflect the final clean state

---

## Notable v3.7.0 Breaking Changes (not applicable to konk, documented for awareness)

- All `--experimental-*` flags removed — konk does not use any
- etcd v2 store/API completely removed — konk does not use v2
- `grpc.WithBlock` no longer honored in `clientv3.New()` — only affects Go library consumers
- Individual arch Docker tags (`-amd64`, `-arm64`) being phased out — konk uses plain version tags