# Section 6 — konk-service pods health (all namespaces)

Checks all pods created and managed by KonkService CRs across every namespace.
Covers three pod types, each with its own role in the konk data path.

---

## Pod types checked

### 1. kubectl-apiservice pods (`component=apiservice`)

**Role:** Registers and maintains APIService objects inside bulk-konk. Each KonkService CR results in one of these pods. It watches the APIService state and re-applies it if deleted or drifted.

**Label selector:** `app.kubernetes.io/component=apiservice`
**Fallback name match:** `konk-service-apiservice` or `kubectl-apiservice` (excludes `-test` suffix)

**Checks per pod:**

| Check | Trigger | Output |
|---|---|---|
| Running + all containers ready | `READY != X/X` or `STATUS != Running` | `[FAIL] ... X/1 Running — not-ready for Nm` |
| Restart count | `RESTARTS > 0` | `[WARN] ... N restart(s) — not running continuously since creation` |
| Recently recovered | Ready within last 30m AND pod older than 10m | `[WARN] ... recently recovered — became Ready Nm ago (pod age: Xm)` |

**Summary line:**
- `[PASS] all N kubectl-apiservice pods are Running and all containers ready`

---

### 2. kubeconfig pods (`component=kubeconfig`)

**Role:** Renews the 12-hour client certificate stored in the konk-service-kubeconfig Secret. If this pod is scaled to 0 or crashing, the client cert will expire and APIService registration will break.

**Label selector:** `app.kubernetes.io/component=kubeconfig`
**Fallback name match:** `konk-service-kubeconfig`

**Checks per pod:** Same as kubectl-apiservice — Running/ready, restart count, recently recovered.

**Summary line:**
- `[PASS] all N kubeconfig (reconcile) pods are Running and all containers ready`

---

### 3. apiservice-test pods (`component=apiservice-test`)

**Role:** Runs a readiness probe against the APIService endpoint inside bulk-konk. If this pod is `0/1 Running`, the APIService it backs is unreachable from inside konk — this is the canary for the 503 pattern that caused the gov-stg-2 cert expiry incident.

**Label selector:** `app.kubernetes.io/component=apiservice-test`
**Fallback name match:** `apiservice-test` or `kubectl-apiservice-test`

**Checks per pod:**

| Check | Trigger | Output |
|---|---|---|
| CrashLoopBackOff / Error | status matches | `[FAIL] ... CrashLoopBackOff` |
| Readiness probe failing | `ready_containers < total AND Running` | `[FAIL] ... readiness probe failing (APIService unavailable)` |
| Restart count | `RESTARTS > 0` | `[WARN] ... N restart(s) — not running continuously since creation` |
| Probe flapping (events) | `>10 Unhealthy events` in last ~1h | `[WARN] ... readiness probe flapping — N Unhealthy events over Xm` |
| Recently recovered | Ready within last 30m AND pod older than 10m | `[WARN] ... recently recovered — became Ready Nm ago (pod age: Xm)` |

**Summary lines:**
- `[PASS] N apiservice-test pods present, all ready, no probe flapping` — fully clean
- `[PASS] N apiservice-test pods present, all currently ready — N warning(s)` — ready but with probe history

---

### 4. Per-KonkService deployment completeness

For each KonkService CR, verifies that both required Deployments exist and have ≥1 available replica:
- `component=kubeconfig` — cert renewal
- `component=apiservice` (or `kubectl-apiservice` suffix) — APIService registration

**Summary line:**
- `[PASS] all N KonkServices have their required konk-service Deployments running (kubeconfig + kubectl-apiservice)`

---

## Flags that affect section 6

| Flag | Effect |
|---|---|
| `--skip-exec` | Skips per-pod `kubectl get pod -o json` fetches — disables recently-recovered detection and disables the not-ready duration on fail lines. Restart count check still runs (reads from existing listing). |

---

## Restart count vs. recently recovered — when each fires

| Scenario | Restart count warn | Recently recovered warn |
|---|---|---|
| Pod ran fine for 3 days, briefly disrupted by etcd restart, recovered | No (restarts=0, probe failure ≠ container restart) | Yes (became ready within 30m) |
| Pod container crashed and restarted | Yes (restarts>0) | Yes if restart was within last 30m |
| Pod has been crashing for days (CrashLoopBackOff) | Yes (restarts>0) | No (also a FAIL) |
| Pod healthy, running continuously | No | No |

The restart count is **persistent** — it accumulates and never resets without a pod deletion.
The recently-recovered warning is **time-windowed** — it only fires within 30 minutes of recovery.
