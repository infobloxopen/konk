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
RUN <<'PATCH' cat > staging/src/k8s.io/apiserver/pkg/endpoints/filters/traces.go
package filters

import (
	"net/http"
	"go.opentelemetry.io/otel/trace"
)

// WithTracing is a no-op passthrough — otelhttp removed to fix CVE-2023-45142.
func WithTracing(handler http.Handler, tp trace.TracerProvider) http.Handler {
	return handler
}
PATCH

RUN <<'PATCH' cat > staging/src/k8s.io/component-base/tracing/utils.go
package tracing

import (
	"context"
	"net/http"

	"go.opentelemetry.io/otel/exporters/otlp"
	"go.opentelemetry.io/otel/exporters/otlp/otlpgrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	oteltrace "go.opentelemetry.io/otel/trace"

	"k8s.io/client-go/transport"
	"k8s.io/component-base/tracing/api/v1"
)

func NewProvider(ctx context.Context,
	tracingConfig *v1.TracingConfiguration,
	addedOpts []otlpgrpc.Option,
	resourceOpts []resource.Option,
) (oteltrace.TracerProvider, error) {
	if tracingConfig == nil {
		return oteltrace.NewNoopTracerProvider(), nil
	}
	opts := append([]otlpgrpc.Option{}, addedOpts...)
	if tracingConfig.Endpoint != nil {
		opts = append(opts, otlpgrpc.WithEndpoint(*tracingConfig.Endpoint))
	}
	opts = append(opts, otlpgrpc.WithInsecure())
	driver := otlpgrpc.NewDriver(opts...)
	exporter, err := otlp.NewExporter(ctx, driver)
	if err != nil {
		return nil, err
	}
	res, err := resource.New(ctx, resourceOpts...)
	if err != nil {
		return nil, err
	}
	sampler := sdktrace.NeverSample()
	if tracingConfig.SamplingRatePerMillion != nil && *tracingConfig.SamplingRatePerMillion > 0 {
		sampler = sdktrace.TraceIDRatioBased(float64(*tracingConfig.SamplingRatePerMillion) / float64(1000000))
	}
	bsp := sdktrace.NewBatchSpanProcessor(exporter)
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithSampler(sdktrace.ParentBased(sampler)),
		sdktrace.WithSpanProcessor(bsp),
		sdktrace.WithResource(res),
	)
	return tp, nil
}

// WithTracing is a no-op passthrough — otelhttp removed to fix CVE-2023-45142.
func WithTracing(handler http.Handler, tp oteltrace.TracerProvider, serviceName string) http.Handler {
	return handler
}

// WrapperFor is a no-op passthrough — otelhttp removed to fix CVE-2023-45142.
func WrapperFor(tp oteltrace.TracerProvider) transport.WrapperFunc {
	return func(rt http.RoundTripper) http.RoundTripper {
		return rt
	}
}

func Propagators() propagation.TextMapPropagator {
	return propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{})
}
PATCH

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
