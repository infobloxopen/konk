# Konk Operator Deployment Fixes — Complete Reference

> **Image:** `v0.2.1-199-g26bef61` (branch: `release/cve-remediations-july26`)

## Overview of All Fixes

This document covers the three-layer fix approach for konk operator deployments:

| Layer | Component | What It Fixes |
|-------|-----------|---------------|
| **Init Container** | `fix-helm-orphans` + `fix-stale-ca` | Helm adoption deadlock + stale CA secrets |
| **Pre-install Hook** | `fix-helm-orphans` Job | Helm orphan resources on upgrades |
| **Post-upgrade Hook** | `post-upgrade` Job | Stale deployments (ghost containers) |

Additionally, two **external scripts** handle issues that can't be fixed by the operator itself:

| Script | Issue | When to Use |
|--------|-------|-------------|
| `fix-x509-issues.sh` | CA mismatch after etcd re-bootstrap | apiserver logs: `certificate signed by unknown authority` |
| `fix-missing-certificates.sh` | cert-manager Certificate CRs deleted | apiserver logs: `certificate has expired` (multiple SNs, different dates) |

---

## Issue 1: Helm Orphan Deadlock

> **Note:** Both the init container AND the pre-install/pre-upgrade hooks coexist.
> - **Init container** → fixes orphans on fresh installs (where Helm blocks hooks from running)
> - **Hooks** → fix orphans on upgrades (where Helm allows hooks to run before applying)
> - Both are idempotent — running both is safe (the second finds 0 to patch)

## Problem

When the konk operator needs to do a **fresh `helm install`** (no release history exists), Helm validates that all existing resources can be adopted **before** running pre-install hooks. If resources have `app.kubernetes.io/managed-by: Helm` labels but are missing `meta.helm.sh/release-name` annotations, Helm refuses to proceed — and the hook never executes.

This creates a deadlock: the hook that fixes orphans can never run because the orphan issue blocks Helm before it reaches the hook stage.

## Why Hooks Alone Don't Work

```
Helm install (no release history):
  1. Render templates
  2. Check resource conflicts  ← FAILS (SA missing annotations)
  3. Run pre-install hooks     ← NEVER REACHED
  4. Apply resources
```

On `helm upgrade` (release exists), hooks run before validation — which is why hooks work on us-dev-4 (existing release) but not us-dev-2 (orphaned release deleted).

## Solution: Operator Init Container

Move the orphan fix to an **init container** on the operator deployment. It runs before the operator starts, using the operator's SA (cluster-admin equivalent `manager-role`).

### Flow

```
1. Operator pod scheduled
2. Init container (fix-helm-orphans-init) starts
3. Lists Konk CRs → aggregate/bulk-konk
4. Lists Etcd CRs → aggregate/bulk-konk-etcd
5. For each CR: scans resources with label selector:
     app.kubernetes.io/managed-by=Helm,app.kubernetes.io/instance=<cr-name>
6. Patches ONLY resources missing meta.helm.sh/release-name annotation
7. Skips resources that already have correct annotations
8. Logs summary per resource type
9. Init container exits 0
10. Operator container starts → reconciles → Helm adopts fixed resources → install succeeds
```

### What It Fixes

| Resource | Namespace | Action |
|----------|-----------|--------|
| ServiceAccount `bulk-konk` | aggregate | PATCH annotations |
| Service `bulk-konk` | aggregate | PATCH |
| Secret `bulk-konk-imagepullsecret` | aggregate | PATCH |
| Deployment `bulk-konk` | aggregate | PATCH |
| Deployment `bulk-konk-init` | aggregate | PATCH |
| Certificate `bulk-konk-ingress-client` | aggregate | PATCH |
| Certificate `bulk-konk-requestheader-proxy-client` | aggregate | PATCH |
| Certificate `bulk-konk-requestheader-self-signed` | aggregate | PATCH |
| Issuer `bulk-konk-requestheader` | aggregate | PATCH |
| Issuer `bulk-konk-requestheader-self-signed` | aggregate | PATCH |
| ClusterRole `bulk-konk-certs-role` | cluster | PATCH |
| ClusterRoleBinding `bulk-konk-certs-rb` | cluster | PATCH |

### What It Does NOT Touch

- Resources that already have correct annotations → **skipped**
- KonkService CRs → not scanned (they have release history, upgrade path works)
- Backend app pods (ipam-importexport, keys-importexport, redirect) → not konk's responsibility

## Implementation

### Files Changed

| File | Change |
|------|--------|
| `cmd/konk-service/fix_helm_orphans_init.go` | New subcommand `fix-helm-orphans-init` — discovers CRs, calls shared fix logic |
| `cmd/konk-service/main.go` | Register new subcommand |
| `helm-charts/konk-operator/templates/deployment.yaml` | Add init container |
| `cmd/konk-service/fix_helm_orphans.go` | Improved logging (patched/skipped/errored per type) |

### Operator Deployment Template

```yaml
initContainers:
  - name: fix-helm-orphans
    image: "{{ .Values.relatedImages.kindRepository }}:{{ .Values.relatedImages.kind }}"
    command: ["/usr/local/bin/konk-service", "fix-helm-orphans-init"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      runAsUser: 65534
      capabilities:
        drop: ["ALL"]
    resources:
      limits:
        cpu: 100m
        memory: 64Mi
```

### Disable If Needed

Set `initOrphanFix.skip=true` in operator values or env var `SKIP_ORPHAN_FIX=true`.

## Logging Output (Expected)

```
Checking Konk CR aggregate/bulk-konk for orphaned resources...
  PATCH serviceaccounts/aggregate "bulk-konk" — adding meta.helm.sh/release-name=bulk-konk, release-namespace=aggregate
  serviceaccounts in aggregate: 1 found, 1 patched, 0 already-ok, 0 errors
  PATCH services/aggregate "bulk-konk" — adding meta.helm.sh/release-name=bulk-konk, release-namespace=aggregate
  services in aggregate: 1 found, 1 patched, 0 already-ok, 0 errors
  PATCH secrets/aggregate "bulk-konk-imagepullsecret" — ...
  secrets in aggregate: 1 found, 1 patched, 0 already-ok, 0 errors
  PATCH deployments/aggregate "bulk-konk" — ...
  PATCH deployments/aggregate "bulk-konk-init" — ...
  deployments in aggregate: 2 found, 2 patched, 0 already-ok, 0 errors
  PATCH certificates/aggregate "bulk-konk-ingress-client" — ...
  PATCH certificates/aggregate "bulk-konk-requestheader-proxy-client" — ...
  PATCH certificates/aggregate "bulk-konk-requestheader-self-signed" — ...
  certificates in aggregate: 3 found, 3 patched, 0 already-ok, 0 errors
  PATCH issuers/aggregate "bulk-konk-requestheader" — ...
  PATCH issuers/aggregate "bulk-konk-requestheader-self-signed" — ...
  issuers in aggregate: 2 found, 2 patched, 0 already-ok, 0 errors
  PATCH cluster-scoped clusterroles "bulk-konk-certs-role" — ...
  cluster-scoped clusterroles: 1 found, 1 patched, 0 already-ok, 0 errors
  PATCH cluster-scoped clusterrolebindings "bulk-konk-certs-rb" — ...
  cluster-scoped clusterrolebindings: 1 found, 1 patched, 0 already-ok, 0 errors
  Patched 12 orphaned resource(s) for release aggregate/bulk-konk
Checking Etcd CR aggregate/bulk-konk-etcd for orphaned resources...
Fixed 12 total orphaned resource(s) across all CRs
```

On subsequent runs (resources already fixed):
```
Checking Konk CR aggregate/bulk-konk for orphaned resources...
  serviceaccounts in aggregate: 1 found, 0 patched, 1 already-ok, 0 errors
  services in aggregate: 1 found, 0 patched, 1 already-ok, 0 errors
  ...
No orphaned resources found across all CRs — nothing to fix
```

## Cascade Effect After Fix

Once the init container fixes orphans and bulk-konk installs:

```
Init container patches orphans
  → Operator reconciles bulk-konk → Helm adopts resources → install succeeds
    → bulk-konk deployment updates to v0.2.1-193 images
      → Konk apiserver starts with current CA cert
        → KonkService reconcile triggers (new image tag)
          → kubeconfig pods restart → regenerate kubeconfigs with current CA
            → apiservice pods restart → connect to bulk-konk → x509 errors gone
              → 17/17 konk-service deployments healthy
```

## Commits

| SHA | Message |
|-----|---------|
| `9f966f7` | fix: add init container to operator for orphan fix before reconcile |
| `e604609` | fix: improve orphan fix logging — show patched/skipped/errored per resource type |

## Relation to Pre-Install Hooks

The hooks remain in place as a **belt-and-suspenders** approach:
- **Init container** → fixes orphans on fresh installs (where hooks can't run)
- **Pre-install hooks** → fixes orphans on upgrades (where hooks DO run)
- Both are idempotent — running both is safe (second one finds 0 to patch)

---

## Issue 2: Stale CA in Kubeconfig Secrets (Init Container — `fix-stale-ca`)

### Problem

After an etcd re-bootstrap, kubeadm generates a new CA keypair in `bulk-konk-ca`. The existing
kubeconfig-cert secrets still have certs signed by the OLD CA. cert-manager's ClusterIssuer
(`bulk-konk-kubeadm-ca`) now references the new CA, but the existing secrets are never re-issued
because cert-manager considers them valid (not expired, Certificate CR exists).

**Symptom:** bulk-konk apiserver logs `x509: certificate signed by unknown authority`

### What the Init Container Does (fix-stale-ca)

Runs as part of the operator init container alongside fix-helm-orphans:

```
1. Read current bulk-konk CA fingerprint from secret 'bulk-konk-ca' in aggregate namespace
2. For each KonkService namespace, find *-kubeconfig-cert secrets
3. Extract the CA cert from each secret and compare fingerprint
4. If CA fingerprint doesn't match → secret is stale
5. DELETE the stale secret (cert-manager will re-issue with correct CA)
6. Log summary: X stale secrets deleted
```

### After Init Container Completes

The operator then triggers KonkService reconciles → new deployments roll out → pods
mount fresh secrets with correct CA → x509 errors resolve.

### Implementation

| File | Purpose |
|------|---------|
| `cmd/konk-service/fix_stale_ca.go` | Compares CA fingerprints, deletes stale secrets |
| `cmd/konk-service/main.go` | Integrated into `fix-helm-orphans-init` subcommand |

---

## Issue 3: Stale Deployments — Ghost Containers (Post-Upgrade Hook)

### Problem

After a konk-service chart upgrade that renames deployments (e.g. adding `-test` suffix),
old deployments remain in the namespace. These run the old `kind` container image and
connect to bulk-konk with potentially outdated certs or wrong configurations.

### What the Post-Upgrade Hook Does

```yaml
annotations:
  "helm.sh/hook": post-install,post-upgrade
  "helm.sh/hook-weight": "0"
  "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
```

The `post-upgrade` Job:
1. Lists all Deployments in the namespace
2. Compares against `VALID_DEPLOYMENTS` env var (comma-separated list of expected deployment names)
3. Checks for `GHOST_CONTAINERS` (containers named `kind` that shouldn't exist in new chart)
4. Deletes any Deployment not in the valid list that has a ghost container

### Implementation

| File | Purpose |
|------|---------|
| `cmd/konk-service/post_upgrade.go` | Lists deploys, identifies ghosts, deletes stale |
| `helm-charts/konk-service/templates/post-upgrade-hook.yaml` | Hook Job + RBAC (SA, Role, RoleBinding) |

---

## Issue 4: Hook ImagePullSecrets Race Condition (SA Fix)

### Problem

On clusters with private registries, hook Jobs need `imagePullSecrets` to pull the konk-service
image. The hook creates a ServiceAccount, and a cluster controller patches it with pull secrets
AFTER creation. But the pod is created ~2s later and Kubernetes copies SA imagePullSecrets into
the pod spec at admission time only (not retroactively).

**Result:** Hook pod gets `ImagePullBackOff` because it started before the SA was patched.

### Fix: imagePullSecrets on ServiceAccount Template

Added `imagePullSecrets` directly to the ServiceAccount in both hook templates:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ ... }}-fix-helm-orphans
  annotations:
    "helm.sh/hook": pre-install,pre-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- range . }}
  {{- if kindIs "string" . }}
  - name: {{ . }}
  {{- else }}
  - name: {{ .name }}
  {{- end }}
  {{- end }}
{{- end }}
```

This eliminates the race condition — the SA has pull secrets at creation time.

### Files Changed

| File | Change |
|------|--------|
| `helm-charts/konk-service/templates/pre-install-hook.yaml` | Added imagePullSecrets to SA |
| `helm-charts/konk-service/templates/post-upgrade-hook.yaml` | Added imagePullSecrets to SA |

---

## Issue 5: Volume-Based Rollout Restart

### Problem

After the init container deletes stale kubeconfig-cert secrets and cert-manager re-issues them,
existing konk-service pods still have the OLD cert mounted. Kubernetes secret volumes sync
within ~60s, but Go HTTP clients may cache TLS configs at startup.

### Fix

The operator deployment uses a `configmap-hash` annotation on the pod template. When the
init container runs, it updates a ConfigMap that triggers a rolling restart of all pods
that mount it. This ensures pods restart and reload fresh certs from the re-issued secrets.

---

## Issue 6: Missing Certificate CRs (External — Not Fixed by Operator)

### Problem

On some clusters (e.g. gov-stg-2), ALL Certificate CRs have been deleted (0 exist across
the entire cluster). This can happen from:
- cert-manager CRD reinstall (old CRD deleted → all CRs gone → new CRD installed)
- Cluster migration or cleanup scripts

Without Certificate CRs, cert-manager cannot auto-renew the kubeconfig-cert secrets.
The 12hr-TTL certs expire and are never replaced.

**Symptom:** bulk-konk apiserver logs `certificate has expired or is not yet valid` with
MULTIPLE distinct serial numbers and different expiry dates (each from a different namespace,
each expired at a different time when its last-issued cert ran out).

### Key Distinction from Issue 2

| | Issue 2 (Stale CA) | Issue 6 (Missing Certs) |
|---|---|---|
| **Certificate CRs** | Exist | Missing (0 on cluster) |
| **cert-manager** | Working (can renew) | Broken (can't renew, no CR) |
| **Error message** | `signed by unknown authority` | `certificate has expired` |
| **Trigger** | etcd re-bootstrap | CRD reinstall / external deletion |
| **Fix** | Delete stale secret → cert-manager re-issues | Recreate Certificate CR → cert-manager can renew |

### This is NOT a Pod Memory Caching Issue

Pods mount the kubeconfig-cert secret as a volume. Kubelet syncs the volume contents when
the secret changes (~60s). But since cert-manager never updates the secret (no Certificate
CR exists), the volume always has the expired cert. The problem is in the secret, not the pod.

### Fix: External Script

```bash
./fix-missing-certificates.sh --apply
```

The script:
1. Discovers KonkService namespaces
2. Finds secrets with `cert-manager.io/certificate-name` annotation but no corresponding Certificate CR
3. Extracts Certificate manifests from Helm release secrets (they were deployed by the operator)
4. Applies them → cert-manager resumes auto-renewal

---

## Complete Component Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ Operator Pod                                                         │
├─────────────────────────────────────────────────────────────────────┤
│ Init Container: fix-helm-orphans                                     │
│   ├─ fix-helm-orphans-init: patches Helm adoption annotations       │
│   └─ fix-stale-ca: deletes kubeconfig-cert secrets with wrong CA    │
├─────────────────────────────────────────────────────────────────────┤
│ Main Container: konk-operator (Helm operator)                        │
│   └─ Watches Konk/KonkService/Etcd CRs → helm install/upgrade       │
└─────────────────────────────────────────────────────────────────────┘

Per KonkService release (each namespace):
┌─────────────────────────────────────────────────────────────────────┐
│ Pre-install/Pre-upgrade Hook: fix-helm-orphans                       │
│   └─ Job: patches orphan resources (belt-and-suspenders with init)   │
│   └─ SA has imagePullSecrets (eliminates race condition)             │
├─────────────────────────────────────────────────────────────────────┤
│ Helm Install/Upgrade (operator reconcile)                            │
│   ├─ Certificate CRs (kubeconfig, server, requestheader)             │
│   ├─ Deployments (kubeconfig, apiservice, apiservice-test)           │
│   ├─ Secrets, ConfigMaps, RBAC                                       │
│   └─ ClusterIssuer, Issuer                                           │
├─────────────────────────────────────────────────────────────────────┤
│ Post-install/Post-upgrade Hook: post-upgrade                         │
│   └─ Job: deletes stale deployments with ghost 'kind' container      │
│   └─ SA has imagePullSecrets (eliminates race condition)             │
└─────────────────────────────────────────────────────────────────────┘
```

---

## All Commits

| SHA | Message | What |
|-----|---------|------|
| `9f966f7` | fix: add init container to operator for orphan fix before reconcile | Init container for Helm orphan fix |
| `e604609` | fix: improve orphan fix logging — show patched/skipped/errored per type | Better logging |
| `8bc4ee8` | fix: volume-based rollout restart after stale CA fix | Trigger pod restart after cert re-issue |
| (uncommitted) | SA imagePullSecrets in hook templates | Fix hook ImagePullBackOff race condition |
| (uncommitted) | e2e script label selector fixes | Correct hook detection in Section 0.1 |

---

## Deployment Order

1. Build image with all fixes → `v0.2.1-199-g26bef61`
2. Deploy to cluster (DC PR or manual)
3. Operator pod starts → init container runs:
   - Patches Helm orphans (if any)
   - Detects & deletes stale CA secrets (if any)
4. Operator starts → reconciles all CRs → triggers upgrades
5. Pre-install hooks run per namespace (idempotent orphan fix)
6. Helm applies chart resources (including Certificate CRs)
7. Post-upgrade hooks run per namespace (delete stale deployments)
8. All pods restart with fresh certs → healthy state

---

## Validation

Run the e2e script to verify all issues are resolved:

```bash
bash scripts/e2e-konk-test.sh --hook
```

Key sections to check:
- **0.1** — Hooks completed successfully
- **0.2** — Init container patched orphans + fixed stale CA
- **6** — All konk-service pods healthy
- **7** — CA trust chain valid
- **10** — No `certificate has expired` errors in bulk-konk apiserver
