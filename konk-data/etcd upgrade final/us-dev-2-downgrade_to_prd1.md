# us-dev-2 → prd-1 konk-operator downgrade: etcd data dir silently flips

Rollback rehearsal on **us-dev-2**: konk-operator downgraded from the
release-branch build to **`v0.2.1-138-g8b64bf7-j170`**, the version `prd-1`
currently pins (`envs/prod/prd-1/konk-operator-version.txt`). Goal was to prove
the prod rollback path before it is needed.

**Verified state at the time of writing:** all pods green — `bulk-konk-etcd-0`
`1/1 Running`, 0 restarts; `bulk-konk` `1/1 Running`. The downgrade *looks*
clean. It is not. etcd came up on a **brand-new empty database** and the previous
data is orphaned on the same PVC.

Context: `2026-08-25`, cluster `us-dev-2`, namespace `aggregate`,
kube context `teleport.services.sdp.infoblox.com-us-dev-2`.

---pp

## Executive summary

The downgrade did not migrate etcd data, and it did not fail loudly either. The
two charts disagree about where etcd's data directory lives, so the older chart
looked in a path that did not exist yet, found nothing, and bootstrapped a fresh
single-member cluster.

| | Chart on `-138` (prd-1) | Chart on release branch |
|---|---|---|
| image | `bitnami/etcd:3.4.14-debian-10-r0` | `cgr.dev/infoblox.com/etcd:3.7.0` |
| container command | `/scripts/setup.sh` | *(image entrypoint)* |
| PVC mount | `/bitnami/etcd` | `/var/lib/etcd` |
| `ETCD_DATA_DIR` | `/bitnami/etcd/data` | `/var/lib/etcd` *(PVC root)* |
| client certs | `/opt/bitnami/etcd/certs/client/` | `/etc/etcd/certs/client` |

Because the data dir is **PVC-root/`data`** on one chart and **PVC-root** on the
other, the same PVC presents as empty to whichever chart you switch *to*. That
is symmetric — **it applies to the upgrade exactly as much as the downgrade.**
This is the finding that matters for prod, and it is not a rollback-only risk.

A green pod is not evidence the switch preserved data. Both probes are
`exec /scripts/probes.sh`, which only asks whether etcd answers on `:2379` — not
which cluster it is, nor whether it has any data. **A blank etcd is a healthy
etcd by that check.**

---

## 1. What actually happened — StatefulSet revision trail

`kubectl get controllerrevision -n aggregate -l app.kubernetes.io/instance=bulk-konk-etcd`

| Rev | Time | Image | Command | Data dir | Result |
|-----|------|-------|---------|----------|--------|
| 5 | 6d20h | `cgr.dev/infoblox.com/etcd:3.7.0` | image entrypoint | `/var/lib/etcd` | healthy, pre-downgrade |
| 6 | ~09:18 | `cgr.dev/…etcd:3.7.0` | `/scripts/setup.sh` | `/bitnami/etcd` | **CrashLoopBackOff** |
| 7 | ~09:21 | `bitnami/etcd:3.4.14-debian-10-r0` | `/scripts/setup.sh` | `/bitnami/etcd/data` | green, **empty DB** |

**Rev 6** is a half-applied state: the old chart's bitnami *wiring* landed on the
new chart's *distroless* image. `/scripts/setup.sh` has a `#!/bin/bash` shebang
and the Chainguard image has no shell, so:

```
exec /scripts/setup.sh: no such file or directory
```

That is the shebang interpreter missing, not the script. The ConfigMap was
mounted correctly via subPath.

**Rev 7** completed the downgrade to the full bitnami default image, which *does*
have a shell — so the process started, the probe passed, and the pod went green
against a database it had just created from scratch:

```
added member 132d3f2b2031a7d7 to cluster e9e217a51a7c2cee   ← new cluster ID
etcdserver: 132d3f2b2031a7d7 as single-node
etcdserver: setting up the initial cluster version to 3.4
```

Cascade while etcd was down: `bulk-konk` restarted 5× on
`dial tcp 100.64.143.55:2379: connect: connection refused` →
`"command failed" err="context deadline exceeded"`. It recovered on its own once
rev 7 came up — against the empty DB.

---

## 2. Measured impact — smaller than the disk figures suggest

Both databases are still on the PVC. `etcdctl snapshot status`:

| | Path | Keys | Logical size | Revision |
|---|---|---|---|---|
| **Old** (3.7-written, orphaned) | `/bitnami/etcd/member/snap/db` | **225** | 4.4 MB | 523773 |
| **New** (3.4.14, live) | `/bitnami/etcd/data/member/snap/db` | **213** | 618 KB | — |

**Delta ≈ 12 keys.** Note the on-disk `db` file for the old cluster is 16.8 MB
while its logical content is 4.4 MB — the rest is free pages from compaction
churn. Reading file size as data volume overstates the loss by ~4×; use
`snapshot status`, not `ls`.

The live keyspace is entirely apiserver bootstrap scaffolding — no custom
resources at all:

```
74 /registry/clusterroles          11 /registry/namespaces
43 /registry/clusterrolebindings    8 /registry/prioritylevelconfigurations
33 /registry/apiregistration.k8s.io 7 /registry/roles
13 /registry/flowschemas            7 /registry/rolebindings
11 /registry/services               2 /registry/ranges
```

**Why it was survivable:** konk's etcd holds almost nothing durable. The
`Konk` / `KonkService` / `Etcd` CRs live in the **parent** cluster, so
konk-service and the operator re-register APIServices and RBAC automatically —
that is the 33 `apiregistration` keys reappearing unaided. State was *re-derived
from declarative source*, which is not the same as *recovered*.

The fresh cluster is also effectively static — 212 → 213 keys and 524 kB →
618 kB over ~15 min — so there is no write-contamination clock to race. The old
`member/` directory is untouched since `09:17`.

---

## 3. Why the PVC normally has to be deleted, and why it didn't this time

Historically every etcd version switch on this cluster required deleting the PVC.
The mechanism:

- etcd **refuses to open a data dir written by a newer version**. `3.7 → 3.4` is
  several minors backward; there is no configuration in which 3.4 reads a
  3.7 data dir. When the data dir path is unchanged, etcd opens it, rejects it,
  and crashloops. Deleting the PVC "fixes" that by handing etcd an empty
  directory.
- This time the chart moved the data dir *along with* the image, so 3.4 never
  saw the 3.7 data. It got a virgin directory and bootstrapped.

**Both outcomes work by the same means — etcd receives an empty directory.** The
difference is only how it is obtained: explicitly by deleting the PVC, or
accidentally by a path flip. The accidental form is strictly more dangerous
because it is silent, and it happens to leave the old data recoverable.

There is no auto-recovery mechanism here. Do not rely on the downgrade being
non-destructive.

---

## 4. Implications for prod

Four clusters currently pin `-138`, i.e. the bitnami layout:

| Cluster | konk-operator |
|---|---|
| `prd-1` | `v0.2.1-138-g8b64bf7-j170` |
| `us-com-1` | `v0.2.1-138-g8b64bf7-j170` |
| `eu-com-1` | `v0.2.1-138-g8b64bf7-j170` |
| `eu-stg-1` | `v0.2.1-138-g8b64bf7-j170` |

Upgrading any of them onto the release-branch chart flips
`/bitnami/etcd/data` → `/var/lib/etcd` and will present an empty etcd, green
probes, and no error. Rolling back flips it the other way with the same result.
**Neither direction is currently a data-preserving operation.**

Whether that is acceptable depends entirely on whether the konk instance on that
cluster holds objects that exist *only* inside konk. On us-dev-2 it did not.
That must be verified per cluster before the prod switch, not assumed from this
rehearsal.

Mitigation to settle before prod: either pin `ETCD_DATA_DIR` and the PVC mount
so the path is identical across both charts, or treat the switch as an explicit
rebuild with a logical export/re-apply of konk-hosted objects. A snapshot
restore will **not** bridge `3.7 → 3.4` — the snapshot format does not downgrade
either.

Minimum guard before any future switch:

```bash
etcdctl snapshot save   /tmp/pre-switch.db    # before touching versions
etcdctl snapshot status /tmp/pre-switch.db    # record the key count
# after the switch, compare key counts — that is the regression check
```

---

## 5. Secondary findings

**5.1 etcd major-version regression.** Rev 7 runs `etcd 3.4.14`, built with
**Go 1.12.17**, on a `debian-10` base — all long EOL. Confirmed in-pod via
`etcd --version`. Treat `-138` as a CVE-exposed floor, not a safe resting state.

**5.2 etcd dropped 3 members → 1.** `sts/bulk-konk-etcd` is at `replicas: 1`;
PVCs `data-bulk-konk-etcd-{0,1,2}` are all still Bound (124d). The live pod env
has `ETCD_INITIAL_ADVERTISE_PEER_URLS` but **no** `ETCD_INITIAL_CLUSTER` or
`ETCD_INITIAL_CLUSTER_STATE` — the single-member-with-no-cluster-config state
that DC commit `88fe00de24c` predicted. The `statefulset.replicaCount: 3` pin
that guards against this is on branch `us-dev-2-update-konk-operator-7bbe64c`,
which is **not merged**, so it never applied.

**5.3 Monitoring scrapes etcd's client port in plaintext.** etcd logs, every
15–30s:

```
embed: rejected connection from "100.64.30.85:47870"
  (error "tls: first record does not look like a TLS handshake", ServerName "")
```

Resolved to `infra-monitoring-alloy-11` (`100.64.30.85`) **and**
`prometheus-federated-prometheus-0` (`100.64.54.34`). Both are hitting `:2379`
without TLS. This contradicts the reasoning in DC commit `88fe00de24c`, which
asserts federated-prometheus is not a consumer because it selects PodMonitors
labelled `federated-prometheus` — it *is* scraping, via the
`prometheus.io/scrape` annotation path rather than PodMonitor. The double-scrape
argument in that commit needs revisiting on that basis.

---

## Open items

1. **Which 12 keys were lost?** `snapshot status` gives counts, not a key list.
   Diffing requires restoring the old snapshot into a scratch data dir and
   starting a throwaway etcd on a spare port. Until that is done, "this
   rehearsal cost nothing" is unconfirmed.
2. **Make the data dir path stable across both charts** — the single change that
   converts this from a silent data-discard into a normal rolling upgrade.
3. **Decide the fate of the orphaned `member/` dir** on the us-dev-2 PVC. It is
   inert but consumes space and will confuse the next person to look.
4. **Add a real etcd health signal** — key count or `endpoint status` revision —
   so "green pod, empty database" cannot pass unnoticed again.
5. **Verify per-cluster** whether konk holds non-re-derivable objects before the
   prod switch.
