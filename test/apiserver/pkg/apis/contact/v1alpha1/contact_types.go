



package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// +genclient
// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object

// Contact
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
