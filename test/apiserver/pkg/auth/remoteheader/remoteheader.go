package remoteheader

import (
	"net/http"

	restclient "k8s.io/client-go/rest"
	"k8s.io/klog"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
)

var log = logf.Log.WithName("remoteheader")

func init() {
	if err := restclient.RegisterAuthProviderPlugin("remoteheader", factory); err != nil {
		klog.Fatalf("Failed to register oidc auth plugin: %v", err)
	}
}

func factory(clusterAddress string, config map[string]string, persister restclient.AuthProviderConfigPersister) (restclient.AuthProvider, error) {

	return &provider{}, nil

}

type provider struct{}

// WrapTransport allows the plugin to create a modified RoundTripper that
// attaches authorization headers (or other info) to requests.
func (p *provider) WrapTransport(h http.RoundTripper) http.RoundTripper {
	return &roundTripper{
		wrapped: h,
	}
}

type roundTripper struct {
	wrapped http.RoundTripper
}

func (r *roundTripper) RoundTrip(req *http.Request) (*http.Response, error) {

	log.Info("dumping headers", "req.Header", req.Header)

	// shallow copy of the struct
	r2 := new(http.Request)
	*r2 = *req
	// deep copy of the Header so we don't modify the original
	// request's Header (as per RoundTripper contract).
	r2.Header = make(http.Header)
	for k, s := range req.Header {
		r2.Header[k] = s
	}

	return r.wrapped.RoundTrip(req)
}

// Login allows the plugin to initialize its configuration. It must not
// require direct user interaction.
func (p *provider) Login() error {
	return nil
}
