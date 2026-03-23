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
