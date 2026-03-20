package example

import (
	"context"

	"k8s.io/apimachinery/pkg/apis/meta/internalversion"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
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
		storage: bugged,
		hackNS:  true,
	}
}

// hackFilepath wraps the FilepathREST storage and overrides NamespaceScoped.
// It explicitly delegates every REST interface so that the apiserver framework
// can discover supported verbs via type assertions on this wrapper.
type hackFilepath struct {
	storage rest.Storage
	hackNS  bool
}

var _ rest.Storage = &hackFilepath{}
var _ rest.Scoper = &hackFilepath{}
var _ rest.Creater = &hackFilepath{}
var _ rest.Updater = &hackFilepath{}
var _ rest.GracefulDeleter = &hackFilepath{}
var _ rest.CollectionDeleter = &hackFilepath{}
var _ rest.Getter = &hackFilepath{}
var _ rest.Lister = &hackFilepath{}

func (h *hackFilepath) New() runtime.Object {
	return h.storage.New()
}

func (h *hackFilepath) NamespaceScoped() bool {
	return h.hackNS
}

func (h *hackFilepath) Get(ctx context.Context, name string, options *metav1.GetOptions) (runtime.Object, error) {
	return h.storage.(rest.Getter).Get(ctx, name, options)
}

func (h *hackFilepath) NewList() runtime.Object {
	return h.storage.(rest.Lister).NewList()
}

func (h *hackFilepath) List(ctx context.Context, options *internalversion.ListOptions) (runtime.Object, error) {
	return h.storage.(rest.Lister).List(ctx, options)
}

func (h *hackFilepath) ConvertToTable(ctx context.Context, object runtime.Object, tableOptions runtime.Object) (*metav1.Table, error) {
	return h.storage.(rest.Lister).ConvertToTable(ctx, object, tableOptions)
}

func (h *hackFilepath) Create(ctx context.Context, obj runtime.Object, createValidation rest.ValidateObjectFunc, options *metav1.CreateOptions) (runtime.Object, error) {
	return h.storage.(rest.Creater).Create(ctx, obj, createValidation, options)
}

func (h *hackFilepath) Update(ctx context.Context, name string, objInfo rest.UpdatedObjectInfo, createValidation rest.ValidateObjectFunc, updateValidation rest.ValidateObjectUpdateFunc, forceAllowCreate bool, options *metav1.UpdateOptions) (runtime.Object, bool, error) {
	return h.storage.(rest.Updater).Update(ctx, name, objInfo, createValidation, updateValidation, forceAllowCreate, options)
}

func (h *hackFilepath) Delete(ctx context.Context, name string, deleteValidation rest.ValidateObjectFunc, options *metav1.DeleteOptions) (runtime.Object, bool, error) {
	return h.storage.(rest.GracefulDeleter).Delete(ctx, name, deleteValidation, options)
}

func (h *hackFilepath) DeleteCollection(ctx context.Context, deleteValidation rest.ValidateObjectFunc, options *metav1.DeleteOptions, listOptions *internalversion.ListOptions) (runtime.Object, error) {
	return h.storage.(rest.CollectionDeleter).DeleteCollection(ctx, deleteValidation, options, listOptions)
}
