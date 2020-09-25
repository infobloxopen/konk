



package contactadmission

import (
	"context"
	aggregatedadmission "github.com/infobloxopen/konk/test/apiserver/plugin/admission"
	aggregatedinformerfactory "github.com/infobloxopen/konk/test/apiserver/pkg/client/informers_generated/externalversions"
	aggregatedclientset "github.com/infobloxopen/konk/test/apiserver/pkg/client/clientset_generated/clientset"
	genericadmissioninitializer "k8s.io/apiserver/pkg/admission/initializer"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/apiserver/pkg/admission"
)

var _ admission.Interface 											= &contactPlugin{}
var _ admission.MutationInterface 									= &contactPlugin{}
var _ admission.ValidationInterface 								= &contactPlugin{}
var _ genericadmissioninitializer.WantsExternalKubeInformerFactory 	= &contactPlugin{}
var _ genericadmissioninitializer.WantsExternalKubeClientSet 		= &contactPlugin{}
var _ aggregatedadmission.WantsAggregatedResourceInformerFactory 	= &contactPlugin{}
var _ aggregatedadmission.WantsAggregatedResourceClientSet 			= &contactPlugin{}

func NewContactPlugin() *contactPlugin {
	return &contactPlugin{
		Handler: admission.NewHandler(admission.Create, admission.Update),
	}
}

type contactPlugin struct {
	*admission.Handler
}

func (p *contactPlugin) ValidateInitialization() error {
	return nil
}

func (p *contactPlugin) Admit(ctx context.Context, a admission.Attributes, o admission.ObjectInterfaces) error {
	return nil
}

func (p *contactPlugin) Validate(ctx context.Context, a admission.Attributes, o admission.ObjectInterfaces) error {
	return nil
}

func (p *contactPlugin) SetAggregatedResourceInformerFactory(aggregatedinformerfactory.SharedInformerFactory) {}

func (p *contactPlugin) SetAggregatedResourceClientSet(aggregatedclientset.Interface) {}

func (p *contactPlugin) SetExternalKubeInformerFactory(informers.SharedInformerFactory) {}

func (p *contactPlugin) SetExternalKubeClientSet(kubernetes.Interface) {}
