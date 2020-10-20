// Code generated by informer-gen. DO NOT EDIT.

package v1alpha1

import (
	"context"
	time "time"

	examplev1alpha1 "github.com/infobloxopen/konk/test/apiserver/pkg/apis/example/v1alpha1"
	clientset "github.com/infobloxopen/konk/test/apiserver/pkg/client/clientset_generated/clientset"
	internalinterfaces "github.com/infobloxopen/konk/test/apiserver/pkg/client/informers_generated/externalversions/internalinterfaces"
	v1alpha1 "github.com/infobloxopen/konk/test/apiserver/pkg/client/listers_generated/example/v1alpha1"
	v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	runtime "k8s.io/apimachinery/pkg/runtime"
	watch "k8s.io/apimachinery/pkg/watch"
	cache "k8s.io/client-go/tools/cache"
)

// ContactInformer provides access to a shared informer and lister for
// Contacts.
type ContactInformer interface {
	Informer() cache.SharedIndexInformer
	Lister() v1alpha1.ContactLister
}

type contactInformer struct {
	factory          internalinterfaces.SharedInformerFactory
	tweakListOptions internalinterfaces.TweakListOptionsFunc
	namespace        string
}

// NewContactInformer constructs a new informer for Contact type.
// Always prefer using an informer factory to get a shared informer instead of getting an independent
// one. This reduces memory footprint and number of connections to the server.
func NewContactInformer(client clientset.Interface, namespace string, resyncPeriod time.Duration, indexers cache.Indexers) cache.SharedIndexInformer {
	return NewFilteredContactInformer(client, namespace, resyncPeriod, indexers, nil)
}

// NewFilteredContactInformer constructs a new informer for Contact type.
// Always prefer using an informer factory to get a shared informer instead of getting an independent
// one. This reduces memory footprint and number of connections to the server.
func NewFilteredContactInformer(client clientset.Interface, namespace string, resyncPeriod time.Duration, indexers cache.Indexers, tweakListOptions internalinterfaces.TweakListOptionsFunc) cache.SharedIndexInformer {
	return cache.NewSharedIndexInformer(
		&cache.ListWatch{
			ListFunc: func(options v1.ListOptions) (runtime.Object, error) {
				if tweakListOptions != nil {
					tweakListOptions(&options)
				}
				return client.ExampleV1alpha1().Contacts(namespace).List(context.TODO(), options)
			},
			WatchFunc: func(options v1.ListOptions) (watch.Interface, error) {
				if tweakListOptions != nil {
					tweakListOptions(&options)
				}
				return client.ExampleV1alpha1().Contacts(namespace).Watch(context.TODO(), options)
			},
		},
		&examplev1alpha1.Contact{},
		resyncPeriod,
		indexers,
	)
}

func (f *contactInformer) defaultInformer(client clientset.Interface, resyncPeriod time.Duration) cache.SharedIndexInformer {
	return NewFilteredContactInformer(client, f.namespace, resyncPeriod, cache.Indexers{cache.NamespaceIndex: cache.MetaNamespaceIndexFunc}, f.tweakListOptions)
}

func (f *contactInformer) Informer() cache.SharedIndexInformer {
	return f.factory.InformerFor(&examplev1alpha1.Contact{}, f.defaultInformer)
}

func (f *contactInformer) Lister() v1alpha1.ContactLister {
	return v1alpha1.NewContactLister(f.Informer().GetIndexer())
}
