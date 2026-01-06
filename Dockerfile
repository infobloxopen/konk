# Multi-stage build: Build helm-operator with updated Go version
FROM golang:1.25.5-alpine AS go-builder

# Install necessary build tools
RUN apk add --no-cache git make bash

# Clone and build operator-sdk/helm-operator
WORKDIR /workspace
RUN git clone --depth 1 --branch v1.42.0 https://github.com/operator-framework/operator-sdk.git && \
    cd operator-sdk && \
    go get -u golang.org/x/crypto && \
    go mod tidy && \
    make build/helm-operator

# Extract helm-operator binary
FROM quay.io/operator-framework/helm-operator:v1.42.0 AS original

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
