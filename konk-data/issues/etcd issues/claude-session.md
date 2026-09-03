# Etcd Upgrade Session — 2026-08-03

## Goal

Upgrade etcd in the `release/upgrade-etcd` branch of `infobloxopen/konk` to
`cgr.dev/infoblox.com/etcd:3.7.1` (started at 3.7.0, bumped to 3.7.1 after CVE
scan).

---

## What Was Done

### 1. Identified relevant commits from `release/cve-remediations-july26`

The same upgrade had already been done in `release/cve-remediations-july26`.
Two commits were identified as relevant:

- `b4dd9fa` — **Use cgr.dev image for etcd**: switches registry from
  `gcr.io/etcd-development/etcd` to `cgr.dev/infoblox.com/etcd:3.7.0` in
  `etcd/Chart.yaml`, `etcd/values.yaml`, `konk/values.yaml`.
- `0fadeeb` — **fix(ci): retag public etcd image in KIND**: adds `ETCD_CHART_IMG`
  variable to Makefile and pulls/retags the public gcr.io image so KIND nodes
  have it pre-loaded with `IfNotPresent` pull policy (cgr.dev is private).

Cherry-picking was ruled out because both commits would conflict — the
`release/upgrade-etcd` branch was at `v3.5.17`/`v3.6.8` while the commits
expected `v3.5.17`/`v3.6.13` as the base.

### 2. Created a fresh commit on `release/upgrade-etcd`

Applied the equivalent changes directly as commit `e13f6ed`:

| File | Change |
|------|--------|
| `helm-charts/etcd/Chart.yaml` | `version: 1.0.0 → 1.1.0`, `appVersion: 3.5.17 → 3.7.0` |
| `helm-charts/etcd/values.yaml` | registry/repo/tag → `cgr.dev` / `infoblox.com/etcd` / `3.7.0` |
| `helm-charts/konk/values.yaml` | same image block updated |
| `helm-charts/konk/README.md` | values table updated to reflect cgr.dev |
| `Makefile` | added `ETCD_IMG`/`ETCD_CHART_IMG` vars + pull/retag logic in `kind-load-konk` |

### 3. CVE scan on etcd:3.7.0

Scanned `gcr.io/etcd-development/etcd:v3.7.0` (same content as the cgr.dev
image, retagged) using `wiz-scan.zsh`.

**Result:** 1 HIGH CVE — `GHSA-hrxh-6v49-42gf` in `google.golang.org/grpc`
v1.81.0 (affects `/usr/local/bin/etcd`, `etcdctl`, `etcdutl`). Fixed in grpc
v1.82.1. Verdict: `WARN_BY_POLICY`.

### 4. Bumped to etcd:3.7.1 to fix the CVE

Confirmed `gcr.io/etcd-development/etcd:v3.7.1` exists and scanned it —
**PASSED_BY_POLICY**, zero findings. Created commit `9deaa9d`:

| File | Change |
|------|--------|
| `helm-charts/etcd/Chart.yaml` | `version: 1.1.0 → 1.1.1`, `appVersion: 3.7.0 → 3.7.1` |
| `helm-charts/etcd/values.yaml` | tag `3.7.0 → 3.7.1` |
| `helm-charts/konk/values.yaml` | tag `3.7.0 → 3.7.1` |
| `helm-charts/konk/README.md` | values table updated |
| `Makefile` | `ETCD_IMG`/`ETCD_CHART_IMG` bumped to `v3.7.1`/`3.7.1` |

Both commits pushed to `release/upgrade-etcd` on GitHub.

---

## How We Found the Konk Image Is on DockerHub, Not Harbor

When attempting to scan the deployed konk-operator version
`v0.2.1-154-g1de007e-j20`, we tried pulling from:

```
harbor.services.sdp.infoblox.com/infobloxcto/konk:v0.2.1-154-g1de007e-j20
```

This failed with `NOT_FOUND`. The DC repo values files pointed to
`harbor.services.sdp.infoblox.com/infobloxcto/konk` as the image repository,
and `crane ls` on that project showed tags — but none with a `-j` (Jenkins build
number) suffix. The tags in harbor (e.g. `v0.2.1-154-gd45a403`) also had
different commit hashes from what we expected.

**Root cause found by reading the `Jenkinsfile`:**

```groovy
GIT_VERSION = "${env.GIT_DESCRIBE}-j${env.BUILD_NUMBER}"
```

Jenkins appends `-j<BUILD_NUMBER>` to the git describe output. And the push
step uses:

```groovy
withDockerRegistry([credentialsId: "dockerhub-bloxcicd", url: ""])
```

`url: ""` is DockerHub (the default Docker registry). The `IMG` in the Makefile
is `infoblox/konk:$(GIT_VERSION)`. So Jenkins-built images go to:

```
infoblox/konk:<version>-j<build>   ← DockerHub
```

Not to Harbor. The harbor project gets images from a different CI pipeline
(GitHub Actions / the `release/cve-remediations-july26` branch builds), which
uses a different tag format without the `-j` suffix.

**Correct image ref for Wiz scanning of Jenkins builds:**

```bash
zsh wiz-scan.zsh infoblox/konk:v0.2.1-157-g9deaa9d-j24
```

---

## CVE Scan Results for konk-operator v0.2.1-157-g9deaa9d-j24

All 16 findings are in `/usr/local/bin/helm-operator` — **not introduced by
the etcd upgrade**. Summary of policy-failing ones:

| CVE | Severity | Library | Fixed In |
|-----|----------|---------|----------|
| CVE-2026-33186 💥 | CRITICAL | `google.golang.org/grpc` v1.75.1 | 1.79.3 |
| CVE-2026-29181 💥 | HIGH | `go.opentelemetry.io/otel` v1.37.0 | 1.41.0 |
| CVE-2026-39883 💥 | HIGH | `go.opentelemetry.io/otel/sdk` v1.37.0 | 1.43.0 |
| CVE-2026-24051 | HIGH | `go.opentelemetry.io/otel/sdk` v1.37.0 | 1.40.0 |
| CVE-2026-53488 | HIGH | `github.com/containerd/containerd` v1.7.29 | 1.7.33 |
| CVE-2026-46680 💥 | HIGH | `github.com/containerd/containerd` v1.7.29 | 1.7.32 |
| CVE-2026-35469 | HIGH | `github.com/moby/spdystream` v0.5.0 | 0.5.1 |
| GHSA-hrxh-6v49-42gf | HIGH | `google.golang.org/grpc` v1.75.1 | 1.82.1 |
| CVE-2026-50151 | HIGH | `oras.land/oras-go/v2` v2.6.0 | 2.6.1 |

Verdict: `WARN_BY_POLICY` (no hard block). The etcd image change itself is
clean.

---

## cgr.dev Auth Note

`cgr.dev/infoblox.com/etcd` requires authentication. To scan it directly:

```bash
chainctl auth configure-docker   # or: crane auth login cgr.dev -u <user> -p <token>
zsh wiz-scan.zsh cgr.dev/infoblox.com/etcd:3.7.1
```

Since `cgr.dev/infoblox.com/etcd:3.7.1` is the public `gcr.io/etcd-development/etcd:v3.7.1`
retagged, the gcr.io scan result (PASSED, zero findings) is equivalent.
