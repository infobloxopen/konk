package contact

import (
	"os"
	"sync"
	"testing"

	"github.com/infobloxopen/konk/test/apiserver/pkg/apis"
	"github.com/onsi/gomega"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	stdlog "k8s.io/klog"
	"sigs.k8s.io/apiserver-builder-alpha/pkg/test/suite"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

var cfg *rest.Config

func TestMain(m *testing.M) {

	env := suite.NewDefaultTestingEnvironment()
	if err := env.StartLocalKubeAPIServer(); err != nil {
		stdlog.Fatal(err)
		return
	}
	if err := env.StartLocalAggregatedAPIServer("example.infoblox.com", "v1alpha1"); err != nil {
		stdlog.Fatal(err)
		return
	}

	apis.AddToScheme(scheme.Scheme)
	cfg = env.LoopbackClientConfig

	code := m.Run()

	stdlog.Info("stopping aggregated-apiserver..")
	if err := env.StopLocalAggregatedAPIServer(); err != nil {
		stdlog.Fatal(err)
		return
	}
	stdlog.Info("stopping kube-apiserver..")
	if err := env.StopLocalKubeAPIServer(); err != nil {
		stdlog.Fatal(err)
		return
	}

	os.Exit(code)
}

// SetupTestReconcile returns a reconcile.Reconcile implementation that delegates to inner and
// writes the request to requests after Reconcile is finished.
func SetupTestReconcile(inner reconcile.Reconciler) (reconcile.Reconciler, chan reconcile.Request) {
	requests := make(chan reconcile.Request)
	fn := reconcile.Func(func(req reconcile.Request) (reconcile.Result, error) {
		result, err := inner.Reconcile(req)
		requests <- req
		return result, err
	})
	return fn, requests
}

// StartTestManager adds recFn
func StartTestManager(mgr manager.Manager, g *gomega.GomegaWithT) (chan struct{}, *sync.WaitGroup) {
	stop := make(chan struct{})
	wg := &sync.WaitGroup{}
	go func() {
		wg.Add(1)
		g.Expect(mgr.Start(stop)).NotTo(gomega.HaveOccurred())
		wg.Done()
	}()
	return stop, wg
}
