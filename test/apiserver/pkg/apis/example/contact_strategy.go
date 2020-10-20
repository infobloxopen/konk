



package example

import (
	"context"

	"k8s.io/klog"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/util/validation/field"
)

// Validate checks that an instance of Contact is well formed
func (ContactStrategy) Validate(ctx context.Context, obj runtime.Object) field.ErrorList {
	o := obj.(*Contact)
	klog.V(5).Infof("Validating fields for Contact %s", o.Name)
	errors := field.ErrorList{}
	// perform validation here and add to errors using field.Invalid
	return errors
}
