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
# NOTE: google.golang.org/grpc is excluded because latest versions pull in
# OpenTelemetry v1.x which conflicts with k8s 1.25.x replace directives
# that pin otel to v0.20.0. Upgrading grpc would require upgrading all
# otel packages, which is invasive for this k8s version.
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
)

# Build the "go get" argument list with @latest for every package.
GO_GET_ARGS=""
for dep in "${PACKAGES[@]}"; do
  GO_GET_ARGS+=" ${dep}@latest"
done

echo "==> Generating patched go.mod for kubernetes ${K8S_VERSION} (Go ${GO_VERSION})" >&2
echo "==> Upgrading: ${PACKAGES[*]}" >&2

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
  for pkg in ${PACKAGES[*]}; do
    go mod edit -dropreplace \"\${pkg}\" 2>/dev/null || true
  done

  echo '    Running go get for upgraded deps...' >&2
  go get ${GO_GET_ARGS} 2>&1 | grep -v '^go:' >&2 || true

  echo '    Running go mod tidy...' >&2
  go mod tidy 2>/dev/null

  # Print resolved versions for visibility
  echo '' >&2
  echo '    Resolved versions:' >&2
  for pkg in ${PACKAGES[*]}; do
    ver=\$(grep \"^\t\${pkg} \" go.mod | head -1 | awk '{print \$2}')
    echo \"      \${pkg} => \${ver}\" >&2
  done
  echo '' >&2

  cat go.mod
" > "${SCRIPT_DIR}/go.mod"

echo "==> Written ${SCRIPT_DIR}/go.mod" >&2
echo "==> Done. Review the changes, then commit build/kubernetes/go.mod" >&2
