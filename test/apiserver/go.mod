module github.com/infobloxopen/konk/test/apiserver

go 1.13

require (
	github.com/go-openapi/loads v0.19.5
	github.com/go-openapi/spec v0.19.12
	github.com/gorilla/websocket v1.4.1 // indirect
	github.com/grpc-ecosystem/go-grpc-middleware v1.0.1-0.20190723091251-e0797f438f94 // indirect
	github.com/onsi/ginkgo v1.14.2
	github.com/onsi/gomega v1.10.1
	github.com/spf13/pflag v1.0.5
	golang.org/x/net v0.0.0-20200707034311-ab3426394381
	k8s.io/apimachinery v0.19.3
	k8s.io/apiserver v0.19.3
	k8s.io/client-go v0.19.3
	k8s.io/klog v1.0.0
	k8s.io/kube-openapi v0.0.0-20200805222855-6aeccd4b50c6
	sigs.k8s.io/apiserver-builder-alpha v1.18.1-0.20201012071248-ca5d7287e44a
	sigs.k8s.io/controller-runtime v0.6.3
)

replace sigs.k8s.io/controller-tools => sigs.k8s.io/controller-tools v0.1.12

replace sigs.k8s.io/kubebuilder => sigs.k8s.io/kubebuilder v1.0.8

replace github.com/markbates/inflect => github.com/markbates/inflect v1.0.4

replace github.com/kubernetes-incubator/reference-docs => github.com/kubernetes-sigs/reference-docs v0.0.0-20170929004150-fcf65347b256

replace sigs.k8s.io/structured-merge-diff => sigs.k8s.io/structured-merge-diff v1.0.1-0.20191108220359-b1b620dd3f06
