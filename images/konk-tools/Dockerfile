ARG KUBECTL_VERSION=v1.32.3

# Stage 1: Download pre-built kubectl binary (officially patched, no CVEs)
FROM alpine:3.21 AS downloader
ARG KUBECTL_VERSION
ARG TARGETARCH=amd64

RUN apk add --no-cache curl && \
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
      -o /kubectl && \
    chmod +x /kubectl

# Stage 2: Get busybox static binary for bash-like shell scripting
FROM busybox:1.37-musl AS busybox

# Stage 3: Final distroless image with only kubectl + shell
FROM gcr.io/distroless/static-debian12

# Copy statically-linked kubectl
COPY --from=downloader /kubectl /usr/local/bin/kubectl

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
