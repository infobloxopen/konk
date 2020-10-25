package example

import (
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apiserver/pkg/registry/generic"
	"k8s.io/apiserver/pkg/registry/rest"
	"k8s.io/klog"
	"sigs.k8s.io/apiserver-builder-alpha/pkg/storage/filepath"
)

// See https://github.com/kubernetes-sigs/apiserver-builder-alpha/pull/533/files#diff-163ee78893222e626ff355526b0c37102559d5c551b0d4c6851e4da2c1ef06f9R12
func NewContactREST(getter generic.RESTOptionsGetter) rest.Storage {
	klog.Infof("new_contact_rest root-directory=%s", rootDir)
	gr := schema.GroupResource{
		Group:    "example.infoblox.com",
		Resource: "contacts",
	}
	opt, err := getter.GetRESTOptions(gr)
	if err != nil {
		klog.Fatal(err)
	}
	bugged := filepath.NewFilepathREST(
		gr,
		opt.StorageConfig.Codec,
		rootDir,
		true,
		func() runtime.Object { return &Contact{} },
		func() runtime.Object { return &ContactList{} },
	)
	return &hackFilepath{
		Storage: bugged,
		hackNS:  true,
	}
}

var _ rest.Scoper = &hackFilepath{}

type hackFilepath struct {
	rest.Storage
	hackNS bool
}

func (h *hackFilepath) NamespaceScoped() bool {
	return h.hackNS
}
