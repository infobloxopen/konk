module github.com/infobloxopen/konk/test/apiserver

go 1.13

require (
	github.com/go-openapi/loads v0.21.2
	github.com/go-openapi/spec v0.20.8
	github.com/google/go-cmp v0.5.6 // indirect
	github.com/onsi/ginkgo v1.16.5
	github.com/onsi/gomega v1.19.0
	github.com/spf13/pflag v1.0.5
	golang.org/x/net v0.0.0-20220225172249-27dd8689420f
	k8s.io/apimachinery v0.23.5
	k8s.io/apiserver v0.23.5
	k8s.io/client-go v0.23.5
	k8s.io/klog v1.0.0
	k8s.io/kube-openapi v0.0.0-20211115234752-e816edb12b65
	sigs.k8s.io/controller-runtime v0.11.0
)

replace sigs.k8s.io/controller-tools => sigs.k8s.io/controller-tools v0.1.12

replace sigs.k8s.io/kubebuilder => sigs.k8s.io/kubebuilder v1.0.8

replace github.com/markbates/inflect => github.com/markbates/inflect v1.0.4

replace github.com/kubernetes-incubator/reference-docs => github.com/kubernetes-sigs/reference-docs v0.0.0-20170929004150-fcf65347b256

replace sigs.k8s.io/structured-merge-diff => sigs.k8s.io/structured-merge-diff v1.0.1-0.20191108220359-b1b620dd3f06
