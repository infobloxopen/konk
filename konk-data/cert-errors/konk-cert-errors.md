# konk Certificate Errors — Common Reference

**Created:** 2026-09-02
**Owner:** Rahul Satal
**Scope:** All certificate-related failures seen in konk (Kubernetes-on-Kubernetes)
aggregated-API deployments across box-dev / com-stage / com-prod.

Entry point for the cert deep-dives in this folder. Start here to identify *which* cert
error you have, then follow the link for the full investigation.

---

## 1. Triage: identify the failure from the error string

There are **three** distinct modes, not two. All are x509/TLS failures between konk and an
aggregated backend, so they look alike — but they involve different certificates, in
different directions, with different fixes.

| # | Error string | Mode | Deep dive |
|---|--------------|------|-----------|
| A | `Unauthorized` in backend logs; konk returns `503` on **list** only | [Client kubeconfig cert expiry (12h)](#3-mode-a--client-kubeconfig-cert-expiry-12h) | [kubeconfig-cert-expiry-503.md](./CA-cert-x509-issue.md/kubeconfig-cert-expiry-503.md), [rotation options](../kubeconfig-cert-rotation-options.md) |
| B | `error trying to reach service: x509: certificate has expired or is not yet valid` | [Backend serving cert expiry (1y)](#4-mode-b--backend-serving-cert-expiry-1y) | §4 below (new, eu-stg-1) |
| C | `tls: failed to verify certificate: x509: certificate signed by unknown authority` | [CA rotation / stale `ca.crt`](#5-mode-c--ca-rotation--stale-cacrt) | [x509_issue-us-dev-5.md](./Client-cert-issue/x509_issue-us-dev-5.md) |

Fast discriminator:

- **"expired"** and the message begins `error trying to reach service:` (emitted by konk's
  **aggregator**) → **Mode B**, serving cert.
- **"expired"** but you only see `Unauthorized`, and only *list* operations break → **Mode A**,
  client cert.
- **"unknown authority"** / `crypto/rsa: verification error` → **Mode C**. Nothing has expired;
  the chain simply does not match. Almost always follows a fresh etcd bootstrap.

### Requested comparison, A vs B

|  | Mode A (us-dev-2, 2026-05-18) | Mode B (eu-stg-1, 2026-09-02) |
|---|---|---|
| **Cert** | `*-konk-service-kubeconfig-cert` | `*-konk-service-server` |
| **Direction** | backend → konk (delegated authn/authz) | konk → backend (aggregation TLS) |
| **Duration** | 12h, `renewBefore: 4h` | 8760h / 1y, **no `renewBefore`** |
| **Symptom** | `Unauthorized` in backend logs, then `503` | `x509: certificate has expired` from the aggregator |
| **Blast radius** | list ops only | whole group-version unreachable |
| **Chain** | kubeadm CA (`<konk>-kubeadm-ca` ClusterIssuer) | konk-service self-signed CA (`CN=konk-service.infoblox`, 2y) |
| **Detected by** | smoke test 503s / backend log noise | `e2e-konk-test.sh` §8 |
| **Time to notice** | hours | ~11 months |

---

## 2. The certificate chains in konk

konk deliberately runs **two independent CA chains** for client auth. Using a cert from one
where the other is expected produces auth failures that look like a product bug — the single
biggest source of wasted debugging time here.

| Chain | CA CN | Cert secret | Cert CN | Used for |
|-------|-------|-------------|---------|----------|
| kubeadm CA | `CN=kubernetes` | `bulk-konk-kubeconfig` | `CN=kubernetes-admin` | admin kubeconfig access to konk |
| requestheader CA | `CN=konk.infoblox` | `bulk-konk-proxy-client` | `CN=core` | front-proxy auth for aggregated API calls |

> **Rule:** smoke tests authenticate via the front-proxy pattern — always take the client cert
> from `bulk-konk-proxy-client`, **never** from the kubeconfig secret. The 50% smoke failure
> on us-dev-5 (2026-05-19) was exactly this testing error, not a production issue.

A **third**, separate self-signed chain lives in the `konk-service` subchart
(`helm-charts/konk-service/templates/ca.yaml`) and is used only for the backend's serving
cert:

```
Issuer <fullname>-self-signed (selfSigned)
  └─ Certificate <fullname>  — CN=konk-service.infoblox, isCA, duration 17520h (2y)
       └─ Issuer <fullname>-ca
            └─ Certificate <fullname>-server  — duration 8760h (1y), no renewBefore  ← Mode B
```

---

## 3. Mode A — client kubeconfig cert expiry (12h)

**Deep dives:** [kubeconfig-cert-expiry-503.md](./CA-cert-x509-issue.md/kubeconfig-cert-expiry-503.md)
(that doc's *Issue 2*; its *Issue 1* is an unrelated `makeslice` panic) and, for the corrected
root cause and the full options analysis,
[kubeconfig-cert-rotation-options.md](../kubeconfig-cert-rotation-options.md).

Cert: `<release>-konk-service-kubeconfig-cert`, from
`helm-charts/konk-service/templates/kubeconfig-certificate.yaml`:

```yaml
subject:
  organizations: [system:masters]
commonName: kubernetes-admin
duration: 12h
renewBefore: 4h              # cert-manager renews at the 8h mark
issuerRef:
  name: <konk>-kubeadm-ca    # ClusterIssuer, kubeadm CA chain
```

**Direction:** backend → konk. The aggregated backend presents this cert when calling konk for
delegated authn/authz, via `--authentication-kubeconfig` / `--authorization-kubeconfig`.

### Root cause (corrected 2026-05-19)

This is a **regression introduced by the distroless Go rewrite** of `reconcile-kubeconfig` —
not a pre-existing problem. Production at the old shell-based commit (`8b64bf7`) had **zero**
cert expiry errors in 30 days.

The rewrite writes the kubeconfig with **embedded cert data** instead of **file references**:

```yaml
# old (shell, works)                    # new (Go rewrite, broken)
client-certificate: tls.crt             client-certificate-data: LS0tLS1C...
client-key: tls.key                     client-key-data: LS0tLS1C...
```

`k8s.io/client-go` TLS transport behaviour:

- **file references** → `dynamicClientCert` → re-reads the cert from disk on **every TLS
  handshake** → always picks up rotations.
- **embedded data** → bytes loaded once into memory → **never re-read** → dead after 12h.

So cert-manager rotates correctly, `reconcile-kubeconfig` updates the Secret correctly, kubelet
syncs the file correctly — and the consumer still uses the stale in-memory copy.

Consumers differ in whether they survive this:

| Deployment | Reloads cert? |
|-----------|---------------|
| `<fullname>-kubectl-apiservice` | **yes** — re-reads the file every 30s in its reconcile loop |
| `<fullname>-delete-apiservice` | n/a — short-lived job |
| application pods (e.g. `tagging-aggregate-api`) | **no** — cached at startup |

**Why only list breaks:** individual GET/POST/PUT/DELETE go through konk's front-proxy path and
authenticate with `bulk-konk-proxy-client` (valid to Jul 2026). **List** additionally trips the
`available_controller`, which health-checks the backend using the backend's *own* kubeconfig
credentials — the expired ones.

**Workaround:** `kubectl rollout restart deployment/<backend> -n <ns>` — buys another 12h.

**Real fix:** Option 7 below.

---

## 4. Mode B — backend serving cert expiry (1y)

**First seen:** eu-stg-1, 2026-09-02, via `e2e-konk-test.sh` section 8.

```
[FAIL] 1/16 aggregated group-versions unreachable
   FAIL bootstrap.bulk.infoblox.com/v1alpha1
        error trying to reach service: x509: certificate has expired or is not yet valid:
        current time 2026-09-02T11:53:55Z is after 2025-09-26T22:28:11Z
        NOTE: its APIService still reports Available=True —
              the availability controller only probes reachability.
```

Cert: `<release>-konk-service-server`, from
`helm-charts/konk-service/templates/certificate.yaml` — note the whole template is skipped if
the chart is given `service.caSecretName`, so confirm that first:

```yaml
secretName: <fullname>-server
duration: 8760h # 1y         # <-- no renewBefore
issuerRef:
  name: <fullname>-ca        # konk-service self-signed CA, 2y
```

**Direction:** konk → backend. This is konk's **aggregator** completing the TLS handshake *to*
the backend Service and rejecting the cert the backend presents, validated against the
APIService `caBundle`.

**Why it hid for months:** the APIService still reports `Available=True`. The availability
controller only probes reachability, not chain validity, so no standard health check flags it.
Nothing surfaces until a client actually calls that group-version.

**Blast radius:** the entire group-version is unreachable — strictly worse than Mode A, which
degrades only list.

### Two candidate explanations — the diagnostic tells you which

Note the expiry: `2025-09-26`, i.e. a cert issued ~Sep 2024 still being presented in Sep 2026.
With no `renewBefore`, cert-manager's default is to renew at 2/3 of lifetime (~8 months), so a
*healthy* Certificate CR should have reissued around May 2025. Two possibilities:

1. **The Secret was never renewed** — the Certificate CR is orphaned/not Ready, or its issuer
   is broken (plausibly downstream of a CA rotation, i.e. Mode C leaving the konk-service chain
   stale). A restart alone will **not** help; the cert must be reissued first.
2. **The Secret was renewed but the pod never reloaded it** — the Mode A shape of problem, on
   the serving side.

Do not assume; run the check:

```bash
NS=<backend namespace>          # for bootstrap.bulk, the bootstrap-app-aggregate-api namespace
kubectl -n $NS get secret <release>-konk-service-server \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates -subject -issuer
kubectl -n $NS get certificate                 # Ready? Not After?
kubectl -n $NS describe certificate <release>-konk-service-server | tail -30
```

### Fix

- **Secret already renewed** (`notAfter` in the future) → only the pod is stale:
  `kubectl -n $NS rollout restart deployment/<backend>`. That alone clears it.
- **Secret itself expired** → force reissue (`kubectl cert-manager renew <cert> -n $NS`, or
  delete the Secret and let cert-manager recreate it), wait for `Ready=True`, **then** rollout
  restart.
- **Also check the 2y CA** (`<fullname>` cert, `duration: 17520h` in `ca.yaml`). If the CA
  itself expired or rotated, reissuing the leaf is not enough — the APIService `caBundle` has to
  match too, which is Mode C territory.

---

## 5. Mode C — CA rotation / stale `ca.crt`

**Deep dive:** [x509_issue-us-dev-5.md](./Client-cert-issue/x509_issue-us-dev-5.md)
(us-dev-5, 2026-06-23, after the etcd `claimName` migration / PR #634 j16)

```
tls: failed to verify certificate: x509: certificate signed by unknown authority
(possibly because of "crypto/rsa: verification error" while trying to verify
candidate authority certificate "kubernetes")
```

Nothing has expired. A **fresh etcd bootstrap** makes `konk-provision` re-run `kubeadm init`,
which mints a **brand-new CA** into `bulk-konk-ca`. Every per-namespace `kubeconfig-cert` Secret
still embeds the **old** CA in its `ca.crt`, and cert-manager has no reason to reissue (not
expired, not marked for renewal). `reconcile-kubeconfig` compares the mounted cert against the
kubeconfig Secret, sees no change, and correctly does nothing — the drift is upstream of it.

**Trigger to watch for:** any operation that deletes the etcd StatefulSet and lets it bootstrap
with `initialClusterState: new`. That includes the etcd 3.4.14 → 3.7.1 migration pre-upgrade
hook.

**Symptom:** `kubectl-apiservice` pods `0/1 Running` across all KonkService namespaces
(tagging-v2, endpoints, hostapp, ntp, ddi, atcapi, redirect, ngp-cp on us-dev-5). Pods start but
cannot reach `bulk-konk.aggregate.svc:6443`.

**Fix:** delete the stale `kubeconfig-cert` Secrets to force reissue → restart
`reconcile-kubeconfig` pods → restart the stuck `0/1` `kubectl-apiservice` pods. Per-namespace
scripts are in the deep-dive; there is also a standing remediation script at
[fix-x509-issues.sh](../issues/x509-issue.md/fix-x509-issues.sh).

**Partial automation already exists:** `cmd/konk-service/fix_stale_ca.go` compares each
KonkService `<name>-konk-service-kubeconfig-cert` `ca.crt` fingerprint against
`aggregate/bulk-konk-ca` and deletes mismatches so cert-manager reissues, retrying up to 5 times
to verify. It covers the **kubeconfig** cert only — not the Mode B server cert.

---

## 6. How the three relate

- **Mode A** — cert rotates fine, consumer never re-reads it (embedded data defeats
  `dynamicClientCert`). Client side.
- **Mode B** — same *shape* on the serving side, but on a 1-year horizon, and possibly
  compounded by the cert never having been reissued at all. Server side.
- **Mode C** — one level up: the **CA** rotates and the leaf Secrets are never marked for
  reissue, so the chain breaks without anything expiring.

All three reduce to: *the certificate changed and the dependent workload was never told.*

---

## 7. Prevention — status

Options analysis and verdicts in full:
[kubeconfig-cert-rotation-options.md](../kubeconfig-cert-rotation-options.md).

| # | Change | Location | Status |
|---|--------|----------|--------|
| Opt 7 | **Primary fix for Mode A** — write the kubeconfig with file references (`ClientCertificate: tls.crt`, `ClientKey: tls.key`, `CertificateAuthority: ca.crt`) instead of embedded data, restoring `client-go`'s `dynamicClientCert`. ~5 lines. No cons identified. | `cmd/konk-service/reconcile_kubeconfig.go` | Implemented on branch `fix/kubeconfig-file-refs`; regression test present in `reconcile_kubeconfig_test.go`. **Not in `origin/main`** as of this local checkout — verify before assuming. |
| Opt 2 | **Defense-in-depth** — on rotation, patch dependent Deployments with `konk.infoblox.com/cert-checksum: <sum>` to force a rolling restart. Needs RBAC `list`+`patch` on deployments. Catches delayed kubelet Secret sync. | `reconcile_kubeconfig.go`, `helm-charts/konk-service/templates/kubeconfig-rbac.yaml` | Implemented on branch `fix/cert-rotation-rollout-restart` (also on origin). **Not in `origin/main`** as of this checkout. |
| Opt 1 | Raise the kubeconfig cert to 1y | — | **REJECTED** — the cert carries `system:masters`; long-lived privileged creds are a security risk, and it masks the reload bug. |
| Opt 6 | Raise to 24–72h + rollout restart | — | Not needed if Opt 7 lands. |
| **new** | Extend the Opt 2 checksum rollout to cover the **server** cert, not just the kubeconfig cert — otherwise Mode B recurs annually | `reconcile_kubeconfig.go` | **PENDING** (from eu-stg-1) |
| **new** | Add an explicit `renewBefore` to the 1y server cert rather than relying on cert-manager's default 1/3-lifetime behaviour | `helm-charts/konk-service/templates/certificate.yaml` | **PENDING** (from eu-stg-1) |
| **new** | Extend `fix_stale_ca.go` to also check server certs and **expiry**, not just CA fingerprint mismatch | `cmd/konk-service/fix_stale_ca.go` | **PROPOSED** (from eu-stg-1) |
| — | Make the etcd pre-upgrade hook annotate all KonkService kubeconfig Certificates with `cert-manager.io/issuing` after STS deletion | etcd chart pre-upgrade hook | **PENDING** (Mode C) |
| — | Use cert-manager `cainjector` to inject the CA rather than embedding `ca.crt` in Secrets, so rotation auto-propagates | charts | **PROPOSED** (Mode C) |
| — | Have `reconcile-kubeconfig` compare against the ClusterIssuer's CA secret via the API rather than the mounted volume, so CA drift is detected even with no reissue | `reconcile_kubeconfig.go` | **PROPOSED** (Mode C) |

---

## 8. Fleet-wide check worth running

Mode B is latent on **any** cluster where a backend pod is older than its serving cert's renewal
point. eu-stg-1 tripped first; the other stage/prod clusters should be checked before they fail
on their own schedule:

```bash
for ctx in us-stg-1 eu-stg-1 prd-1 us-com-1 eu-com-1; do
  for ns in $(kubectl --context $ctx get konkservices -A \
                -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
    for s in $(kubectl --context $ctx -n $ns get secret -o name | grep 'konk-service-server'); do
      exp=$(kubectl --context $ctx -n $ns get $s -o jsonpath='{.data.tls\.crt}' \
            | base64 -d | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
      echo "$ctx $ns $s notAfter=$exp"
    done
  done
done
```

Cross-check each `notAfter` against the age of the pod mounting it — a pod older than the cert's
issuance date is serving a stale cert regardless of what the Secret says.

---

## 9. Related, but not certificate problems

Easily mistaken for cert errors:

- **`makeslice` panic on bare `GET /tags`** — *Issue 1* in
  [kubeconfig-cert-expiry-503.md](./CA-cert-x509-issue.md/kubeconfig-cert-expiry-503.md).
  Presents as `503 stream error: INTERNAL_ERROR`, which looks like an aggregation/TLS failure.
  A `uint64` limit of `MaxUint64` fell through to a `math.MaxInt` fallback and blew up in
  `make()`. Fixed in `v0.1.5-39-g5307097-j62`
  ([atlas.tagging.aggregateapi#83](https://github.com/Infoblox-CTO/atlas.tagging.aggregateapi/pull/83)).
- **Helm orphan annotations** — KonkService Deployments missing `meta.helm.sh/release-name`
  after the same us-dev-5 etcd migration. Independent problem, same trigger event. See
  [annotation-issue.md](../issues/annotation/annotation-issue.md) and
  `cmd/konk-service/fix_helm_orphans_init.go`.
- **Tag export "Tags (0 of 0)"** on us-dev-2 — a 60s `tagging-aggregate-api` timeout, not a cert
  or etcd-migration issue.
- **etcd 3.4.14 → 3.7.1 migration** — the migration changeset itself touches no cert issuance.
  It is only relevant as the *trigger* for Mode C (fresh bootstrap → new CA).
