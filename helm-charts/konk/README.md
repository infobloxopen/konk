# konk

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: v1.25.8](https://img.shields.io/badge/AppVersion-v1.25.8-informational?style=flat-square)

Deploys an instance of konk (kubernetes on kubernetes), typically run by konk-operator

## Values or `Konk` `.spec`

When deploying with konk-operator, these configurations can be overridden in the `Konk` `.spec`.

When deploying with `helm install`, these configurations are values and can be overridden in the [normal way](https://helm.sh/docs/helm/helm_install/#helm-install).

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` |  |
| apiserver.disabledAPIs | list | `["apps/v1","apps/v1beta1","autoscaling/v1","autoscaling/v2beta1","autoscaling/v2beta2","batch/v1","batch/v1beta1","networking.k8s.io/v1","networking.k8s.io/v1beta1","storage.k8s.io/v1","storage.k8s.io/v1beta1"]` | specifies APIs unavailable in Konk. |
| apiserver.extraFlags | object | `{}` | additional command line flags for kube-apiserver. See https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/ for details. |
| apiserver.image.pullPolicy | string | `"Always"` |  |
| apiserver.image.repository | string | `"k8s.gcr.io/kube-apiserver"` |  |
| apiserver.image.tag | string | default is the chart appVersion. | Overrides the image tag |
| apiserver.remoteHeaders.requestheader-extra-headers-prefix | string | `"X-Remote-Extra-"` | sets kube-apiserver's `--requestheader-extra-headers-prefix` option. See https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/ for details. |
| apiserver.remoteHeaders.requestheader-group-headers | string | `"X-Remote-Group"` | sets kube-apiserver's `--requestheader-group-headers` option. |
| apiserver.remoteHeaders.requestheader-username-headers | string | `"X-Remote-User"` | sets kube-apiserver's `--requestheader-username-headers` option. |
| apiserver.resources.limits.memory | string | `"4Gi"` |  |
| apiserver.resources.requests.cpu | string | `"20m"` |  |
| apiserver.resources.requests.memory | string | `"160Mi"` |  |
| apiserver.securityContext | object | `{}` |  |
| apiserver.startupProbe | bool | `true` |  |
| autoscaling.enabled | bool | `false` |  |
| autoscaling.maxReplicas | int | `100` |  |
| autoscaling.minReplicas | int | `1` |  |
| autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| certManager.namespace | string | `nil` |  |
| etcd.operator | bool | `true` | defines how Konk's internal etcd is deployed. `true`: etcd is deployed by konk-operator `false`: etcd is deployed as a sidecar of konk's kube-apiserver |
| etcd.replicaCount | int | `3` |  |
| etcd.resources.limits.memory | string | `"4Gi"` |  |
| etcd.resources.requests.cpu | string | `"10m"` |  |
| etcd.resources.requests.memory | string | `"64Mi"` |  |
| etcd.securityContext | object | `{}` |  |
| fullnameOverride | string | `""` |  |
| imagePullSecrets | list | `[]` |  |
| ingress.annotations."nginx.ingress.kubernetes.io/backend-protocol" | string | `"HTTPS"` |  |
| ingress.className | string | `""` |  |
| ingress.enabled | bool | `false` |  |
| ingress.hosts[0].host | string | `"chart-example.local"` |  |
| ingress.hosts[0].paths | list | `[]` |  |
| ingress.tls | list | `[]` |  |
| kind.image.pullPolicy | string | `"Always"` |  |
| kind.image.repository | string | `"kindest/node"` |  |
| kind.image.tag | string | default is the chart appVersion. | Overrides the image tag |
| kind.resources.limits.memory | string | `"4Gi"` |  |
| kind.resources.requests.cpu | string | `"100m"` |  |
| kind.resources.requests.memory | string | `"128Mi"` |  |
| kind.securityContext | object | `{}` |  |
| nameOverride | string | `""` |  |
| nodeSelector | object | `{}` |  |
| podAnnotations | object | `{}` |  |
| podSecurityContext | object | `{}` |  |
| replicaCount | int | `1` |  |
| scope | string | `"namespace"` | scope can be `cluster` or `namespace`. When scope is `cluster`, Certificates in any namespace can be signed by the konk's Issuer. |
| service.port | int | `6443` |  |
| service.type | string | `"ClusterIP"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| space.enabled | bool | `false` |  |
| tolerations | list | `[]` |  |
