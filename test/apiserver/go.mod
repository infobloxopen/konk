module github.com/infobloxopen/konk/test/apiserver

go 1.13

require (
	cloud.google.com/go v0.54.0 // indirect
	github.com/Azure/go-autorest/autorest v0.11.1 // indirect
	github.com/Azure/go-autorest/autorest/adal v0.9.5 // indirect
	github.com/blang/semver v3.5.1+incompatible // indirect
	github.com/go-openapi/loads v0.21.2
	github.com/go-openapi/spec v0.20.7
	github.com/grpc-ecosystem/go-grpc-middleware v1.0.1-0.20190723091251-e0797f438f94 // indirect
	github.com/imdario/mergo v0.3.10 // indirect
	github.com/onsi/ginkgo v1.16.5
	github.com/onsi/gomega v1.20.1
	github.com/prometheus/procfs v0.2.0 // indirect
	github.com/spf13/cobra v1.1.1 // indirect
	github.com/spf13/pflag v1.0.5
	go.etcd.io/etcd v0.5.0-alpha.5.0.20200910180754-dd1b699fc489 // indirect
	go.uber.org/zap v1.15.0 // indirect
	golang.org/x/net v0.0.0-20220722155237-a158d28d115b
	golang.org/x/time v0.0.0-20200630173020-3af7569d3a1e // indirect
	gomodules.xyz/jsonpatch/v2 v2.1.0 // indirect
	google.golang.org/appengine v1.6.6 // indirect
	google.golang.org/genproto v0.0.0-20201110150050-8816d57aaa9a // indirect
	k8s.io/apiextensions-apiserver v0.19.2 // indirect
	k8s.io/apimachinery v0.25.2
	k8s.io/apiserver v0.19.2
	k8s.io/client-go v0.19.2
	k8s.io/klog v1.0.0
	k8s.io/kube-openapi v0.0.0-20220803162953-67bda5d908f1
	sigs.k8s.io/apiserver-builder-alpha v1.18.1-0.20201012071248-ca5d7287e44a
	sigs.k8s.io/apiserver-network-proxy/konnectivity-client v0.0.14 // indirect
	sigs.k8s.io/controller-runtime v0.6.5
)

replace sigs.k8s.io/controller-tools => sigs.k8s.io/controller-tools v0.1.12

replace sigs.k8s.io/kubebuilder => sigs.k8s.io/kubebuilder v1.0.8

replace github.com/markbates/inflect => github.com/markbates/inflect v1.0.4

replace github.com/kubernetes-incubator/reference-docs => github.com/kubernetes-sigs/reference-docs v0.0.0-20170929004150-fcf65347b256

replace sigs.k8s.io/structured-merge-diff => sigs.k8s.io/structured-merge-diff v1.0.1-0.20191108220359-b1b620dd3f06
