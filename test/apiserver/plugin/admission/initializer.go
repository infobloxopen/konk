



package admission

import (
	aggregatedclientset "github.com/infobloxopen/konk/test/apiserver/pkg/client/clientset_generated/clientset"
	aggregatedinformerfactory "github.com/infobloxopen/konk/test/apiserver/pkg/client/informers_generated/externalversions"
	"k8s.io/apiserver/pkg/admission"
)

// WantsAggregatedResourceClientSet defines a function which sets external ClientSet for admission plugins that need it
type WantsAggregatedResourceClientSet interface {
	SetAggregatedResourceClientSet(aggregatedclientset.Interface)
	admission.InitializationValidator
}

// WantsAggregatedResourceInformerFactory defines a function which sets InformerFactory for admission plugins that need it
type WantsAggregatedResourceInformerFactory interface {
	SetAggregatedResourceInformerFactory(aggregatedinformerfactory.SharedInformerFactory)
	admission.InitializationValidator
}

// New creates an instance of admission plugins initializer.
func New(
	clientset aggregatedclientset.Interface,
	informers aggregatedinformerfactory.SharedInformerFactory,
) pluginInitializer {
	return pluginInitializer{
		aggregatedResourceClient:    clientset,
		aggregatedResourceInformers: informers,
	}
}

type pluginInitializer struct {
	aggregatedResourceClient    aggregatedclientset.Interface
	aggregatedResourceInformers aggregatedinformerfactory.SharedInformerFactory
}

func (i pluginInitializer) Initialize(plugin admission.Interface) {
	if wants, ok := plugin.(WantsAggregatedResourceClientSet); ok {
		wants.SetAggregatedResourceClientSet(i.aggregatedResourceClient)
	}
	if wants, ok := plugin.(WantsAggregatedResourceInformerFactory); ok {
		wants.SetAggregatedResourceInformerFactory(i.aggregatedResourceInformers)
	}
}

