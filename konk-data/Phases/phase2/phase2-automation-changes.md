# Phase 2 — Automation Changes (PR #658)

## Overview

PR [#658](https://github.com/infobloxopen/konk/pull/658) introduces three automated lifecycle mechanisms to handle Helm orphan resources, ghost containers, and stale CA certificates during konk-operator upgrades.

## When Do These Run?

### Reconciliation Triggers (us-dev-4)

The konk-operator is deployed via Flux HelmRelease with a **5-minute reconciliation interval**:

```
Flux HR (vela-system/konk-operator) → spec.interval: 5m
```

The operator itself is a **Helm operator** — it watches Konk, KonkService, and Etcd CRs and runs `helm install/upgrade` for each CR it reconciles. The operator does NOT have an explicit `reconcilePeriod` in `watches.yaml`, so it uses the operator-sdk default (event-driven reconciliation — reconcile on CR changes, not on a fixed schedule).

**Important distinction:** The Flux 5m interval controls how often Flux checks if the **operator chart** needs upgrading. The operator's internal reconciliation of individual CRs is **event-driven** (triggered by CR spec changes, operator restarts, or drift detection).

### What triggers a Helm install/upgrade for each CR?

| Trigger | What happens |
|---------|-------------|
| Operator pod restart | Reconciles ALL CRs → `helm upgrade` for each → hooks fire |
| CR `.spec` change | Reconciles that CR → `helm upgrade` → hooks fire |
| Operator image upgrade (new chart version) | Operator pod restarts → reconciles ALL CRs |
| Manual annotation (`konk.infoblox.com/force-reconcile`) | Reconciles that CR |

## Current State on us-dev-4

### CRs Being Managed

| Namespace | CR Type | Name | Konk Instance |
|-----------|---------|------|---------------|
| aggregate | Konk | bulk-konk | — (is the konk instance) |
| hostapp | KonkService | hostapp-aggregate-api-apiservice | bulk-konk |
| hostapp | KonkService | hostapp-aggregate-api-infra | bulk-konk |
| ngp-cp | KonkService | bootstrap-app-aggregate-api-apiservice | bulk-konk |
| ntp | KonkService | ntp-aggregate-api-apiservice | bulk-konk |
| tagging-v2 | KonkService | tagging-aggregate-api-apiservice | bulk-konk |

### Helm Release History

| Namespace | Release | Status | Version | Last Updated |
|-----------|---------|--------|---------|-------------|
| vela-system | konk-operator | deployed | v78 | 2026-07-15 |
| aggregate | bulk-konk | deployed | v2 | 2026-07-15 |
| aggregate | bulk-konk-etcd | deployed | v2 | 2026-07-14 |
| hostapp | hostapp-aggregate-api-apiservice | deployed | v1 | 2026-07-15 |
| hostapp | hostapp-aggregate-api-infra | deployed | v1 | 2026-07-15 |
| ngp-cp | bootstrap-app-aggregate-api-apiservice | deployed | v1 | 2026-07-15 |
| ntp | ntp-aggregate-api-apiservice | deployed | v1 | 2026-07-15 |
| tagging-v2 | tagging-aggregate-api-apiservice | deployed | v1 | 2026-07-15 |

> Note: The user-provided data showed `bulk-konk` at revision 6 (from 2026-06-25) and `bulk-konk-etcd` at revision 119 (from 2026-06-25). The current state shows revision 2 for both — this means the init container's `cleanupStaleHooks` deleted the old superseded release secrets and the July upgrade resulted in a fresh revision count.

### Operator Pod

```
Pod: konk-operator-77bcff46c4-nr5pv
Container restarts: 0
Init container restarts: 0
Running since: 2026-07-25T23:33:35Z
```

---

## The Three Mechanisms

### 1. Init Container (`fix-helm-orphans-init`)

**Image:** konk-service  
**Command:** `/usr/local/bin/konk-service fix-helm-orphans-init`  
**Runs when:** Operator pod starts (before operator container)  
**Runs how often:** Once per operator pod restart  
**Configurable:** `initOrphanFix.enabled` (default: `true`), `initOrphanFix.skip` sets `SKIP_ORPHAN_FIX=true`

**What it does (in order):**

1. **Cleans up stale hook resources** — Deletes leftover Helm hook Jobs, ServiceAccounts, Roles, RoleBindings (resources with `helm.sh/hook` annotation whose name contains "konk" or "etcd") across all namespaces containing Konk/Etcd CRs. Also deletes leftover cluster-scoped hook ClusterRoles and ClusterRoleBindings.

2. **Deletes non-deployed Helm release secrets** — Removes release secrets in `pending-upgrade`, `pending-install`, or `failed` status (but keeps `deployed` and `superseded`). These leftovers from previous failed upgrades block subsequent attempts.

3. **Fixes orphaned resources for ALL Konk CRs** — Lists all Konk CRs across all namespaces. For each, scans 16 resource types (ServiceAccounts, ConfigMaps, Services, Secrets, Deployments, StatefulSets, Jobs, Roles, RoleBindings, Certificates, Issuers, Ingresses, Spaces, Etcds, HPAs) plus cluster-scoped resources (ClusterRoles, ClusterRoleBindings, ClusterIssuers). Patches any resource that has `app.kubernetes.io/managed-by=Helm` label but is missing `meta.helm.sh/release-name` annotation.

4. **Fixes orphaned resources for ALL Etcd CRs** — Same scan as above but without cluster-scoped resources.

5. **Fixes stale CA certificates** — Reads the current CA fingerprint from `aggregate/bulk-konk-ca` secret. Compares against each KonkService's `*-kubeconfig-cert` secret's `ca.crt`. If the fingerprint differs (stale), deletes the secret so cert-manager re-issues it. Waits up to 50 seconds (5 retries × 10s) for re-issuance, then rollout-restarts deployments that mount the affected kubeconfig secrets.

**Code:** `cmd/konk-service/fix_helm_orphans_init.go`, `cmd/konk-service/fix_stale_ca.go`

---

### 2. Pre-Install/Pre-Upgrade Hook (`pre-install-hook.yaml`)

**Charts:** konk-service, konk  
**Image:** konk-service  
**Command:** `/usr/local/bin/konk-service fix-helm-orphans`  
**Runs when:** Before each `helm install` or `helm upgrade` of an individual CR  
**Runs how often:** Every CR reconciliation that triggers a Helm install/upgrade  
**Configurable:** `hooks.preInstallUpgrade.enabled` (default: `true`)

**What it does:**

1. **Waits for RBAC propagation** — The hook creates its own SA/Role/RoleBinding at weight `-10` and the Job at weight `-5`. Retries listing ServiceAccounts up to 15 times (2s apart) to confirm RBAC is active.

2. **Fixes orphaned resources for THIS release** — Same annotation-patching logic as init container, but scoped to a single namespace and release name (set via `NAMESPACE` and `RELEASE_NAME` env vars).

3. **Optionally scans cluster-scoped resources** — Konk chart sets `SCAN_CLUSTER_SCOPED=true`; KonkService chart does not.

**Helm annotations:**
- RBAC resources: `helm.sh/hook-weight: "-10"`, `hook-delete-policy: before-hook-creation`
- Job: `helm.sh/hook-weight: "-5"`, `hook-delete-policy: before-hook-creation,hook-succeeded`

**Why it's needed even though the init container exists:**
- Init container runs once at operator startup; pre-install hook runs on every individual CR reconciliation
- Catches orphans created AFTER the operator started (e.g., from a failed mid-reconcile)
- Covers manual `helm install/upgrade` operations (no operator involved)
- The Etcd chart hook was removed since the init container already covers Etcd CRs

**Code:** `cmd/konk-service/fix_helm_orphans.go`

---

### 3. Post-Install/Post-Upgrade Hook (`post-upgrade-hook.yaml`)

**Chart:** konk-service only  
**Image:** konk-service  
**Command:** `/usr/local/bin/konk-service post-upgrade`  
**Runs when:** After each `helm install` or `helm upgrade` of a KonkService CR  
**Runs how often:** Every KonkService reconciliation that triggers a Helm install/upgrade  
**Configurable:** `hooks.postInstallUpgrade.enabled` (default: `true`)

**What it does:**

1. **Ghost container cleanup** — Lists KonkService deployments (label `app.kubernetes.io/name=konk-service,app.kubernetes.io/instance=<release>`). Checks each deployment's containers and init containers for old names (default: `"kind"` — the old container name before it was renamed to `"kubeconfig"`). If found, deletes the deployment (Kubernetes strategic merge patch adds new containers without removing renamed ones — deletion is the only fix; the operator recreates it cleanly).

2. **Stale deployment cleanup** — Compares running deployment names against `VALID_DEPLOYMENTS` (comma-separated list computed from chart templates: `*-kubeconfig`, `*-apiservice`, `*-apiservice-test`). Deletes any deployment whose name isn't in the valid set — these are orphans from previous chart versions that used different naming/truncation rules.

**Does NOT do stale CA fix** — Not needed because:
- Init container already ran CA fix before operator started
- `reconcile_kubeconfig.go` handles runtime cert rotations (patches pod template annotation to trigger rollout restart when cert checksum changes)
- Post-upgrade hook's RBAC only has `list` and `delete` on deployments — no secret access

**Code:** `cmd/konk-service/post_upgrade.go`

---

## Execution Flow

```
Operator pod starts
  │
  ├─ Init Container: fix-helm-orphans-init
  │   ├─ Clean stale hooks & pending releases (all namespaces)
  │   ├─ Fix orphan annotations (all Konk & Etcd CRs)
  │   └─ Fix stale CA (all KonkService kubeconfig-cert secrets)
  │
  └─ Operator container starts
      │
      ├─ Reconcile Konk CR (aggregate/bulk-konk)
      │   ├─ Pre-install hook: fix orphans for bulk-konk release
      │   ├─ helm install/upgrade
      │   └─ (no post-upgrade hook — Konk chart doesn't have one)
      │
      ├─ Reconcile Etcd CR (aggregate/bulk-konk-etcd)
      │   └─ helm install/upgrade (no hooks — removed)
      │
      ├─ Reconcile KonkService CR (hostapp/hostapp-aggregate-api-apiservice)
      │   ├─ Pre-install hook: fix orphans for this release
      │   ├─ helm install/upgrade
      │   └─ Post-upgrade hook: cleanup ghosts & stale deployments
      │
      ├─ Reconcile KonkService CR (hostapp/hostapp-aggregate-api-infra)
      │   ├─ Pre-install hook
      │   ├─ helm install/upgrade
      │   └─ Post-upgrade hook
      │
      └─ ... (remaining KonkService CRs)
```

## Answering: "Is it on a scheduled basis?"

**No, the hooks do not run on a fixed schedule.** They are event-driven:

- The **init container** runs when the operator pod starts (deployment rollout, node eviction, OOMKill, etc.)
- The **pre/post hooks** run when the operator reconciles a CR — which happens on:
  - Operator restart (reconciles all CRs)
  - CR spec change
  - Operator image upgrade (DC PR changes version → Flux deploys → operator restarts → reconciles all)

The Flux HelmRelease `spec.interval: 5m` only controls how often Flux checks if the **operator Helm chart** needs updating — it does NOT cause the operator to re-reconcile CRs every 5 minutes.

Looking at the cluster data: the last operator upgrade was `v78` on **2026-07-15**, which triggered reconciliation of all CRs (all KonkService releases show `2026-07-15` as their creation date). The operator pod has been running since **2026-07-25** (likely a node rotation, not a chart upgrade — since the version is still v78).

## Configuration Toggles

| Value | Chart | Default | Purpose |
|-------|-------|---------|---------|
| `initOrphanFix.enabled` | konk-operator | `true` | Enable/disable init container |
| `initOrphanFix.skip` | konk-operator | `false` | Set `SKIP_ORPHAN_FIX=true` env |
| `hooks.preInstallUpgrade.enabled` | konk, konk-service | `true` | Enable/disable pre-install hook |
| `hooks.postInstallUpgrade.enabled` | konk-service | `true` | Enable/disable post-upgrade hook |
