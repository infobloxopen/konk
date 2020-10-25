package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// +genclient
// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object

// Contact
// Custom backends do not work, see https://github.com/kubernetes-sigs/apiserver-builder-alpha/issues/551
// // resource:path=contacts,strategy=ContactStrategy,rest=ContactREST
// +k8s:openapi-gen=true
// +resource:path=contacts,strategy=ContactStrategy
type Contact struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   ContactSpec   `json:"spec,omitempty"`
	Status ContactStatus `json:"status,omitempty"`
}

// ContactSpec defines the desired state of Contact
type ContactSpec struct {
}

// ContactStatus defines the observed state of Contact
type ContactStatus struct {
}
