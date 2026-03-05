ARG GO_VERSION=1.25.5
ARG K8S_VERSION=v1.25.8
ARG CRYPTO_VERSION=v0.45.0

FROM golang:${GO_VERSION}-alpine AS builder
ARG K8S_VERSION
ARG CRYPTO_VERSION

RUN apk add --no-cache git bash make rsync

WORKDIR /workspace
RUN git clone --depth 1 --branch ${K8S_VERSION} https://github.com/kubernetes/kubernetes.git

WORKDIR /workspace/kubernetes

# Patch golang.org/x/crypto to fixed version
RUN go get golang.org/x/crypto@${CRYPTO_VERSION} && \
    go mod tidy && \
    go mod vendor

# Build kubeadm as a fully static binary
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -extldflags '-static'" \
    -o /kubeadm \
    ./cmd/kubeadm

# Output stage - scratch image with just the binary for easy extraction
FROM scratch
COPY --from=builder /kubeadm /kubeadm
