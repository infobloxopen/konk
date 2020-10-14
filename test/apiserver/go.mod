module github.com/infobloxopen/konk/test/apiserver

go 1.13

require (
	github.com/go-openapi/loads v0.19.4
	github.com/go-openapi/spec v0.19.3
	github.com/gogo/protobuf v1.3.1 // indirect
	github.com/gorilla/websocket v1.4.1 // indirect
	github.com/grpc-ecosystem/go-grpc-middleware v1.0.1-0.20190723091251-e0797f438f94 // indirect
	github.com/kubernetes-incubator/reference-docs v0.0.0 // indirect
	github.com/markbates/inflect v1.0.4
	github.com/onsi/ginkgo v1.12.0
	github.com/onsi/gomega v1.9.0
	github.com/pkg/errors v0.9.1
	github.com/spf13/cobra v1.0.0
	github.com/spf13/pflag v1.0.5
	github.com/tmc/grpc-websocket-proxy v0.0.0-20190109142713-0ad062ec5ee5 // indirect
	k8s.io/api v0.19.2
	k8s.io/apimachinery v0.19.2
	k8s.io/apiserver v0.19.2
	k8s.io/client-go v0.19.2
	k8s.io/code-generator v0.19.2
	k8s.io/gengo v0.0.0-20200428234225-8167cfdcfc14
	k8s.io/klog v1.0.0
	k8s.io/kube-aggregator v0.19.2
	k8s.io/kube-openapi v0.0.0-20200805222855-6aeccd4b50c6
	k8s.io/utils v0.0.0-20200729134348-d5654de09c73
	sigs.k8s.io/apiserver-builder-alpha v1.18.1-0.20201012071248-ca5d7287e44a
	sigs.k8s.io/controller-runtime v0.6.0
	sigs.k8s.io/controller-tools v0.1.12 // indirect
	sigs.k8s.io/kubebuilder v1.0.9-0.20200925141511-a2f239880b04
	sigs.k8s.io/structured-merge-diff v0.0.0-20190525122527-15d366b2352e // indirect
	sigs.k8s.io/testing_frameworks v0.1.1
)

replace sigs.k8s.io/controller-tools => sigs.k8s.io/controller-tools v0.1.12

replace sigs.k8s.io/kubebuilder => sigs.k8s.io/kubebuilder v1.0.8

replace github.com/markbates/inflect => github.com/markbates/inflect v1.0.4

replace github.com/kubernetes-incubator/reference-docs => github.com/kubernetes-sigs/reference-docs v0.0.0-20170929004150-fcf65347b256

replace sigs.k8s.io/structured-merge-diff => sigs.k8s.io/structured-merge-diff v1.0.1-0.20191108220359-b1b620dd3f06
