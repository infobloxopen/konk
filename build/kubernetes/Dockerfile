# syntax=docker/dockerfile:1.6
ARG GO_VERSION=1.25.5
ARG K8S_VERSION=v1.32.4

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