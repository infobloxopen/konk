ARG GO_VERSION=1.25.5
ARG K8S_VERSION=v1.25.8

# Stage 1: Build kubectl from patched kubernetes source
FROM golang:${GO_VERSION}-alpine AS k8s-builder
ARG K8S_VERSION

RUN apk add --no-cache git bash make rsync

WORKDIR /workspace
RUN git clone --depth 1 --branch ${K8S_VERSION} https://github.com/kubernetes/kubernetes.git

WORKDIR /workspace/kubernetes

# Copy pre-computed patched go.mod with pinned dependency upgrades.
# Same patched deps as the kubeadm/kube-apiserver build.
COPY build/kubernetes/go.mod go.mod

RUN go mod tidy && \
    go mod vendor

# Build kubectl as a fully static binary
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -extldflags '-static'" \
    -o /kubectl \
    ./cmd/kubectl

# Stage 2: Get busybox static binary for bash-like shell scripting
FROM busybox:1.37-musl AS busybox

# Stage 3: Final distroless image with only kubectl + shell
FROM gcr.io/distroless/static-debian12

# Copy statically-linked kubectl
COPY --from=k8s-builder /kubectl /usr/local/bin/kubectl

# Copy busybox for shell scripting (bash-compatible via sh/ash)
# The konk-service templates use /bin/bash -c, so symlink bash -> busybox
COPY --from=busybox /bin/busybox /bin/busybox

# Create shell symlinks — busybox applets needed by the helm templates
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/sh"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/bash"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/cat"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/date"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/echo"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/grep"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/head"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/sleep"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/sed"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/md5sum"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/true"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/false"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/ls"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/mkdir"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/rm"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/cp"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/chmod"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/wc"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/tail"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/tr"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/cut"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/awk"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/xargs"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/usr/bin/md5sum"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/usr/bin/head"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/usr/bin/tail"]

ENTRYPOINT ["/bin/sh"]
