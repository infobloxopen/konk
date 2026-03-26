# syntax=docker/dockerfile:1.6
ARG GO_VERSION=1.25.5
ARG K8S_VERSION=v1.25.8

FROM golang:${GO_VERSION}-alpine AS builder
ARG K8S_VERSION

RUN apk add --no-cache git bash make rsync

WORKDIR /workspace
RUN git clone --depth 1 --branch ${K8S_VERSION} https://github.com/kubernetes/kubernetes.git

WORKDIR /workspace/kubernetes

# Copy pre-computed patched go.mod with pinned dependency upgrades.
# Regenerate with: make update-kubernetes-deps
COPY go.mod go.mod

# Patch source compatibility for golang-jwt/jwt/v4 v4.5.x:
# NumericDate changed from value to pointer type in v4.5.x
# 1. Change struct field WarnAfter from value to pointer type
# 2. Fix the comparison of the *NumericDate variable (not the int64 parameter)
RUN sed -i 's/WarnAfter jwt\.NumericDate/WarnAfter *jwt.NumericDate/' pkg/serviceaccount/claims.go && \
    sed -i '/private\.Kubernetes\.WarnAfter/{n;s/if warnafter != 0/if warnafter != nil/;}' pkg/serviceaccount/claims.go

# Patch CVE-2023-45142: Remove otelhttp dependency from kube-apiserver.
# Replace otelhttp usages with no-op passthroughs in both files that import it,
# then drop the module from go.mod so it is not vendored into the binary at all.
# Patch files live in build/kubernetes/patches/ (not inlined) for readability.
COPY patches/traces.go staging/src/k8s.io/apiserver/pkg/endpoints/filters/traces.go
COPY patches/utils.go  staging/src/k8s.io/component-base/tracing/utils.go

# Drop otelhttp from go.mod so it is not vendored at all
RUN go mod edit \
    -droprequire go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp \
    -dropreplace go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp && \
    go mod edit \
    -droprequire go.opentelemetry.io/contrib \
    -dropreplace go.opentelemetry.io/contrib

RUN go mod tidy && \
    go mod vendor

# Build kubeadm and kube-apiserver as fully static binaries
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -extldflags '-static'" \
    -o /kubeadm \
    ./cmd/kubeadm

RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -extldflags '-static'" \
    -o /kube-apiserver \
    ./cmd/kube-apiserver

# Final image with both binaries
FROM gcr.io/distroless/static-debian12
COPY --from=builder /kubeadm /usr/local/bin/kubeadm
COPY --from=builder /kube-apiserver /usr/local/bin/kube-apiserver
ENTRYPOINT ["/usr/local/bin/kube-apiserver"]