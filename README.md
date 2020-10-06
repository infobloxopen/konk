# konk

konk - Kubernetes On Kubernetes - is a tool for deploying an independent Kubernetes API server within Kubernetes.

konk can be used as part of a larger application to manage resources via CustomResourceDefinitions and implement a CRUD API for those resources by leveraging kube-apiserver.

konk does not start a kubelet and therefore does not support any resources that require a node such as deployments and pods.

This repo provides a konk helm chart that can be used to deploy an instance of konk with helm, and a konk-operator that watches for konk CRs and will deploy a konk instance for each of them.

## konk chart

Found in [helm-charts/konk](helm-charts/konk).

This chart will deploy konk.

### Example usage:

    helm install my-konk ./helm-charts/konk
    helm test my-konk

## konk operator

konk-operator is generated with operator-sdk and implements a helm operator for the konk chart. Once deployed, `Konk` resources can be created in the cluster and the operator will deploy a konk instance for each of them.

### Optional, stand up KIND

    make kind kind-load-konk
    # Teardown cluster
    make kind-destroy

### Install

    helm install my-konk-operator ./helm-charts/konk-operator

### Create a konk

[examples/konk.yaml](examples/konk.yaml) is a simple manifest for a konk resource.

    % kubectl apply -f https://raw.githubusercontent.com/infobloxopen/konk/master/examples/konk.yaml
    konk.konk.infoblox.com/example-konk created

### Observe your new konk

    % kubectl get pods -l app.kubernetes.io/instance=example-konk
    NAME                                READY   STATUS    RESTARTS   AGE
    example-konk-6b4996448c-skjxw       2/2     Running   0          83s
    example-konk-init-d6cff859c-2w4bm   1/1     Running   0          83s
