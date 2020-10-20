



package v1alpha1_test

import (
	"testing"

	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
	"sigs.k8s.io/apiserver-builder-alpha/pkg/test"
	"k8s.io/client-go/rest"

	"github.com/infobloxopen/konk/test/apiserver/pkg/apis"
	"github.com/infobloxopen/konk/test/apiserver/pkg/client/clientset_generated/clientset"
	"github.com/infobloxopen/konk/test/apiserver/pkg/openapi"
)

var testenv *test.TestEnvironment
var config *rest.Config
var cs *clientset.Clientset

func TestV1alpha1(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecsWithDefaultAndCustomReporters(t, "v1 Suite", []Reporter{test.NewlineReporter{}})
}

var _ = BeforeSuite(func() {
	testenv = test.NewTestEnvironment(apis.GetAllApiBuilders(), openapi.GetOpenAPIDefinitions)
	config = testenv.Start()
	cs = clientset.NewForConfigOrDie(config)
})

var _ = AfterSuite(func() {
	testenv.Stop()
})
