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

# Troubleshooting

konk-operator will update the `status` field on Konk and KonkService resources. The contents here can be particularly helpful for determining why konk is not functioning properly.

Here's an example of a healthy konk status:
```json
% kubectl get konks runner-konk -o jsonpath='{.status.conditions}' | jq
[
  {
    "lastTransitionTime": "2020-11-10T00:29:56Z",
    "status": "True",
    "type": "Initialized"
  },
  {
    "lastTransitionTime": "2020-11-10T00:29:59Z",
    "message": "1. Get the application URL by running these commands:\n  export POD_NAME=$(kubectl get pods --namespace default -l \"app.kubernetes.io/name=konk,app.kubernetes.io/instance=runner-konk\" -o jsonpath=\"{.items[0].metadata.name}\")\n  echo \"Visit http://127.0.0.1:8080 to use your application\"\n  kubectl --namespace default port-forward $POD_NAME 8080:80\n",
    "reason": "InstallSuccessful",
    "status": "True",
    "type": "Deployed"
  }
]
```
`"reason": "InstallSuccessful"` is a good sign!

Here's an example of an unhealthy konk:
```json
% k -n aggregate get konks tagging-aggregate-api-konk -o jsonpath='{.status.conditions}' | jq
[
  {
    "lastTransitionTime": "2020-11-10T13:50:38Z",
    "status": "True",
    "type": "Initialized"
  },
  {
    "lastTransitionTime": "2020-11-10T13:50:41Z",
    "message": "failed to install release: rendered manifests contain a resource that already exists. Unable to continue with install: Service \"tagging-aggregate-api-konk\" in namespace \"aggregate\" exists and cannot be imported into the current release: invalid ownership metadata; label validation error: missing key \"app.kubernetes.io/managed-by\": must be set to \"Helm\"; annotation validation error: missing key \"meta.helm.sh/release-name\": must be set to \"tagging-aggregate-api-konk\"; annotation validation error: missing key \"meta.helm.sh/release-namespace\": must be set to \"aggregate\"",
    "reason": "InstallError",
    "status": "True",
    "type": "ReleaseFailed"
  }
]
```
`"reason": "InstallError"` means there was a problem while trying to reconcile the konk's resources. The message explains exactly what the problem is; there's a resource name conflict: `Service \"tagging-aggregate-api-konk\" in namespace \"aggregate\" exists and cannot be imported into the current release`. One potential solution to this problem is to choose a more unique name for your Konk, but in this particular case the conflicting resource was not longer needed and the problem was resolved by manually deleting it.
