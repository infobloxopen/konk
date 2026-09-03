# Multi-stage build: Build helm-operator with updated Go version
FROM golang:1.27.1-alpine AS go-builder

# Install necessary build tools
RUN apk add --no-cache git make bash

# Clone and build operator-sdk/helm-operator
WORKDIR /workspace
COPY patches/ /workspace/patches/
RUN git clone --depth 1 --branch v1.42.0 https://github.com/operator-framework/operator-sdk.git && \
    cd operator-sdk && \
    git apply /workspace/patches/operator-sdk-upgrade-error-logging.patch && \
    go get golang.org/x/crypto@v0.52.0 \
           golang.org/x/net@v0.55.0 \
           google.golang.org/grpc@v1.79.3 \
           go.opentelemetry.io/otel@v1.43.0 \
           go.opentelemetry.io/otel/sdk@v1.43.0 \
           go.opentelemetry.io/otel/trace@v1.43.0 \
           go.opentelemetry.io/otel/metric@v1.43.0 \
           github.com/moby/spdystream@v0.5.1 \
           github.com/containerd/containerd@v1.7.33 \
           helm.sh/helm/v3@v3.20.2 \
           oras.land/oras-go/v2@v2.6.1 && \
    go mod tidy && \
    make build/helm-operator

# Final stage with distroless base
FROM gcr.io/distroless/static-debian12:nonroot

# Copy the rebuilt helm-operator binary with updated Go version
COPY --from=go-builder /workspace/operator-sdk/build/helm-operator /usr/local/bin/helm-operator

# Copy necessary files
ENV HOME=/opt/helm
COPY --chmod=555 watches.yaml ${HOME}/watches.yaml
COPY --chmod=555 helm-charts ${HOME}/helm-charts
WORKDIR ${HOME}

# Run as non-root user
USER nonroot:nonroot

ENTRYPOINT ["/usr/local/bin/helm-operator"]
CMD ["run"]
