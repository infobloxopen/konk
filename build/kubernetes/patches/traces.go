package filters

import (
	"net/http"
	"go.opentelemetry.io/otel/trace"
)

// WithTracing is a no-op passthrough — otelhttp removed to fix CVE-2023-45142.
func WithTracing(handler http.Handler, tp trace.TracerProvider) http.Handler {
	return handler
}
