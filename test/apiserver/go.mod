module github.com/infobloxopen/konk/test/apiserver

go 1.13

require (
	github.com/go-openapi/analysis v0.19.12 // indirect
	github.com/go-openapi/errors v0.19.9 // indirect
	github.com/go-openapi/jsonpointer v0.19.5 // indirect
	github.com/go-openapi/jsonreference v0.19.5 // indirect
	github.com/go-openapi/loads v0.19.5
	github.com/go-openapi/spec v0.19.11
	github.com/go-openapi/strfmt v0.20.0 // indirect
	github.com/go-openapi/swag v0.19.9 // indirect
	github.com/grpc-ecosystem/go-grpc-middleware v1.0.1-0.20190723091251-e0797f438f94 // indirect
	github.com/mailru/easyjson v0.7.6 // indirect
	github.com/mitchellh/mapstructure v1.4.1 // indirect
	github.com/onsi/ginkgo v1.14.1
	github.com/onsi/gomega v1.10.2
	github.com/spf13/pflag v1.0.5
	go.mongodb.org/mongo-driver v1.4.6 // indirect
	golang.org/x/net v0.0.0-20210119194325-5f4716e94777
	golang.org/x/sys v0.0.0-20210112080510-489259a85091 // indirect
	golang.org/x/text v0.3.5 // indirect
	golang.org/x/tools v0.0.0-20201224043029-2b0845dc783e // indirect
	gopkg.in/yaml.v3 v3.0.0-20200615113413-eeeca48fe776 // indirect
	k8s.io/apimachinery v0.20.2
	k8s.io/apiserver v0.20.1
	k8s.io/client-go v0.20.2
	k8s.io/klog v1.0.0
	k8s.io/kube-openapi v0.0.0-20201113171705-d219536bb9fd
	sigs.k8s.io/apiserver-builder-alpha v1.18.1-0.20201012071248-ca5d7287e44a
	sigs.k8s.io/apiserver-runtime v0.0.0-20210201122150-e20867ae0d8d
	sigs.k8s.io/controller-runtime v0.8.2
)

replace sigs.k8s.io/controller-tools => sigs.k8s.io/controller-tools v0.1.12

replace sigs.k8s.io/kubebuilder => sigs.k8s.io/kubebuilder v1.0.8

replace github.com/markbates/inflect => github.com/markbates/inflect v1.0.4

replace github.com/kubernetes-incubator/reference-docs => github.com/kubernetes-sigs/reference-docs v0.0.0-20170929004150-fcf65347b256

replace sigs.k8s.io/structured-merge-diff => sigs.k8s.io/structured-merge-diff v1.0.1-0.20191108220359-b1b620dd3f06

// avoid breaking change to yaml.v3
replace github.com/googleapis/gnostic => github.com/googleapis/gnostic v0.4.2
