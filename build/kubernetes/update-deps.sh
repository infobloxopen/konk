#!/usr/bin/env bash
# update-deps.sh - Discovers latest versions of vulnerable/outdated dependencies
# in kubernetes source and generates a pinned go.mod for deterministic builds.
#
# Usage: ./update-deps.sh [K8S_VERSION] [GO_VERSION]
#   or:  make update-kubernetes-deps
#
# The generated go.mod is checked into the repo and copied into the Docker
# build so that builds are fully reproducible without network-dependent
# version resolution.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_VERSION="${1:-${K8S_VERSION:-v1.25.8}}"
GO_VERSION="${2:-${GO_VERSION:-1.25.5}}"

# Packages to upgrade – add new entries here as vulnerabilities are discovered.
# NOTE: google.golang.org/protobuf is excluded because v1.34+ removed
# deprecated descriptor fields that github.com/golang/protobuf still uses
# in k8s 1.25.x (Default_FileOptions_PhpGenericServices etc).
PACKAGES=(
  golang.org/x/crypto
  golang.org/x/net
  golang.org/x/sys
  golang.org/x/term
  golang.org/x/text
  golang.org/x/oauth2
  golang.org/x/sync
  golang.org/x/time
  github.com/golang-jwt/jwt/v4
  github.com/opencontainers/selinux
)

# Packages that require specific versions (not @latest) due to compatibility
# constraints with k8s 1.25.x's OpenTelemetry v0.20.0 pinning.
# grpc 1.56.3 is the minimum fix for CVE-2023-44487 (HTTP/2 rapid reset).
# docker/distribution was renamed to github.com/distribution/reference;
# we pin to the last v2 tag that contains the CVE-2023-2253 fix.
PINNED_PACKAGES=(
  "google.golang.org/grpc@v1.56.3"
  "github.com/docker/distribution@v2.8.3+incompatible"
  "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp@v0.44.0"
  "go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc@v0.44.0"
  "go.opentelemetry.io/contrib@v1.19.0"
  "go.opentelemetry.io/otel@v1.19.0"
  "go.opentelemetry.io/otel/trace@v1.19.0"
  "go.opentelemetry.io/otel/metric@v1.19.0"
  "go.opentelemetry.io/otel/sdk@v1.19.0"
  "go.opentelemetry.io/otel/sdk/metric@v1.19.0"
  "go.opentelemetry.io/otel/exporters/otlp@v0.44.0"
  "go.opentelemetry.io/otel/exporters/otlp/otlptrace@v1.19.0"
  "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc@v1.19.0"
  "go.opentelemetry.io/proto/otlp@v1.0.0"
)

# Combine all package names (without versions) for the drop-replace loop
ALL_PACKAGE_NAMES=("${PACKAGES[@]}")
for pinned in "${PINNED_PACKAGES[@]}"; do
  ALL_PACKAGE_NAMES+=("${pinned%%@*}")
done

# Build the "go get" argument list with @latest for every package.
GO_GET_ARGS=""
for dep in "${PACKAGES[@]}"; do
  GO_GET_ARGS+=" ${dep}@latest"
done
# Add pinned packages with their specific versions
for pinned in "${PINNED_PACKAGES[@]}"; do
  GO_GET_ARGS+=" ${pinned}"
done

# Build space-separated list of all package names for shell interpolation
ALL_NAMES_STR=""
for name in "${ALL_PACKAGE_NAMES[@]}"; do
  ALL_NAMES_STR+=" ${name}"
done

echo "==> Generating patched go.mod for kubernetes ${K8S_VERSION} (Go ${GO_VERSION})" >&2
echo "==> Upgrading (latest): ${PACKAGES[*]}" >&2
echo "==> Upgrading (pinned): ${PINNED_PACKAGES[*]}" >&2

docker run --rm "golang:${GO_VERSION}-alpine" sh -c "
  set -e
  apk add --no-cache git bash >/dev/null 2>&1
  echo '    Cloning kubernetes ${K8S_VERSION}...' >&2
  git clone --depth 1 --branch '${K8S_VERSION}' \
    https://github.com/kubernetes/kubernetes.git /workspace/kubernetes 2>/dev/null
  cd /workspace/kubernetes

  # Drop existing replace directives for packages we are upgrading,
  # otherwise the replace pins override the go get versions.
  echo '    Dropping stale replace directives...' >&2
  for pkg in ${ALL_NAMES_STR}; do
    go mod edit -dropreplace \"\${pkg}\" 2>/dev/null || true
  done

  # Also drop replace directives for otel sub-packages that may conflict
  for pkg in \
    go.opentelemetry.io/contrib/propagators \
    go.opentelemetry.io/otel/oteltest \
    go.opentelemetry.io/otel/sdk/export/metric; do
    go mod edit -dropreplace \"\${pkg}\" 2>/dev/null || true
  done

  echo '    Running go get for upgraded deps...' >&2
  go get ${GO_GET_ARGS} 2>&1 | grep -v '^go:' >&2 || true

  echo '    Running go mod tidy...' >&2
  go mod tidy 2>/dev/null

  # Print resolved versions for visibility
  echo '' >&2
  echo '    Resolved versions:' >&2
  for pkg in ${ALL_NAMES_STR}; do
    ver=\$(grep \"^\t\${pkg} \" go.mod | head -1 | awk '{print \$2}')
    echo \"      \${pkg} => \${ver}\" >&2
  done
  echo '' >&2

  cat go.mod
" > "${SCRIPT_DIR}/go.mod"

echo "==> Written ${SCRIPT_DIR}/go.mod" >&2
echo "==> Done. Review the changes, then commit build/kubernetes/go.mod" >&2
