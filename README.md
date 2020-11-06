# konk

konk - Kubernetes On Kubernetes - is a tool for deploying an independent Kubernetes API server within Kubernetes.

konk can be used as part of a larger application to manage resources via CustomResourceDefinitions and implement a CRUD API for those resources by leveraging kube-apiserver. Or implement an [extension API server](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/apiserver-aggregation/) without worrying about [breaking the parent cluster with a non-compliant API](https://github.com/kubernetes/kubernetes/issues/96066).

konk does not start a kubelet and therefore does not support any resources that require a node such as deployments and pods.

This repo provides a konk helm chart that can be used to deploy an instance of konk with helm, and a konk-operator that watches for konk CRs and will deploy a konk instance for each of them.

## konk chart

Found in [helm-charts/konk](helm-charts/konk).

This chart will deploy konk.

### Example usage:

    helm install my-konk ./helm-charts/konk
    helm test my-konk

## konk operator

konk-operator is generated with operator-sdk and implements a helm operator for the konk chart and the konk-service chart. Once deployed, `Konk` and `KonkService` resources can be created in the cluster and the operator will deploy a konk instance and a konk-service instance for each of them.

[Example `Konk` CR](examples/konk.yaml)

## konk service chart

Found in [helm-charts/konk-service](helm-charts/konk-service).

The konk-service chart or `KonkService` CR will deploy the resources required to register an `APIService` in konk. It requires an existing konk to be deployed in the cluster. You need to specify the name of the konk and the name of the service that the `APIService` object being created should point to. This would be specified under `konk.name` and `service.name` in the `values.yaml` file. Also specify the `group` and `version` values to be populated in the generated APIService.

[`KonkService` spec doc](helm-charts/konk-service/values.yaml)

[Example `KonkService`](examples/konk-service.yaml)

### front-proxy ingress

Setting `.spec.ingress.enabled=true` in your `KonkService` will provision front-proxy ingress to the `APIService` you registered in konk. The front-proxy certs are provisioned automatically.

```yaml
kind: KonkService
...
spec:
  ...
  ingress:
    enabled: true
    hosts:
    - host: my-api.example.com
    tls:
    - hosts:
      - my-api.example.com
      secretName: my-api.example.com-tls
```

# Testing

## example apiserver chart

Found in [helm-charts/example-apiserver](helm-charts/example-apiserver).

This chart will deploy an example-apiserver instance, which is a reference implementation of an extension API server and its usage with konk. This chart requires an existing konk to be deployed in the cluster. This chart also assumes that the konk-operator has been deployed to the cluster, since it involves creating a `KonkService` CR.

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

### Deploy example apiserver with konk

    make deploy-example-apiserver
    make test-example-apiserver
