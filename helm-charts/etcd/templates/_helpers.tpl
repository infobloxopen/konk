{{/* vim: set filetype=mustache: */}}

{{/*
Expand the name of the chart.
*/}}
{{- define "etcd.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "etcd.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "etcd.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "etcd.labels" -}}
helm.sh/chart: {{ include "etcd.chart" . }}
{{ include "etcd.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "etcd.selectorLabels" -}}
app.kubernetes.io/name: {{ include "etcd.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Return the proper etcd image name
*/}}
{{- define "etcd.image" -}}
{{- $registryName := .Values.image.registry -}}
{{- $repositoryName := .Values.image.repository -}}
{{- $tag := .Values.image.tag | toString -}}
{{- if .Values.global }}
    {{- if .Values.global.imageRegistry }}
        {{- printf "%s/%s:%s" .Values.global.imageRegistry $repositoryName $tag -}}
    {{- else -}}
        {{- printf "%s/%s:%s" $registryName $repositoryName $tag -}}
    {{- end -}}
{{- else -}}
    {{- printf "%s/%s:%s" $registryName $repositoryName $tag -}}
{{- end -}}
{{- end -}}

{{/*
Return the headless service name
*/}}
{{- define "etcd.headlessServiceName" -}}
{{- printf "%s-headless" (include "etcd.fullname" .) -}}
{{- end -}}

{{/*
Return the peer protocol (http or https)
*/}}
{{- define "etcd.peerProtocol" -}}
{{- if .Values.auth.peer.secureTransport -}}
{{- print "https" -}}
{{- else -}}
{{- print "http" -}}
{{- end -}}
{{- end -}}

{{/*
Return the client protocol (http or https)
*/}}
{{- define "etcd.clientProtocol" -}}
{{- if .Values.auth.client.secureTransport -}}
{{- print "https" -}}
{{- else -}}
{{- print "http" -}}
{{- end -}}
{{- end -}}

{{/*
Create the initial cluster string
*/}}
{{- define "etcd.initialCluster" -}}
{{- $fullname := include "etcd.fullname" . -}}
{{- $headlessService := include "etcd.headlessServiceName" . -}}
{{- $releaseNamespace := .Release.Namespace -}}
{{- $clusterDomain := .Values.clusterDomain -}}
{{- $peerPort := int .Values.service.peerPort -}}
{{- $peerProtocol := include "etcd.peerProtocol" . -}}
{{- $replicaCount := int .Values.replicaCount -}}
{{- $members := list -}}
{{- range $i := until $replicaCount -}}
{{- $members = append $members (printf "%s-%d=%s://%s-%d.%s.%s.svc.%s:%d" $fullname $i $peerProtocol $fullname $i $headlessService $releaseNamespace $clusterDomain $peerPort) -}}
{{- end -}}
{{- join "," $members -}}
{{- end -}}

{{/*
Create the endpoints list for etcdctl
*/}}
{{- define "etcd.endpoints" -}}
{{- $fullname := include "etcd.fullname" . -}}
{{- $headlessService := include "etcd.headlessServiceName" . -}}
{{- $releaseNamespace := .Release.Namespace -}}
{{- $clusterDomain := .Values.clusterDomain -}}
{{- $clientPort := int .Values.service.port -}}
{{- $clientProtocol := include "etcd.clientProtocol" . -}}
{{- $replicaCount := int .Values.replicaCount -}}
{{- $endpoints := list -}}
{{- range $i := until $replicaCount -}}
{{- $endpoints = append $endpoints (printf "%s://%s-%d.%s.%s.svc.%s:%d" $clientProtocol $fullname $i $headlessService $releaseNamespace $clusterDomain $clientPort) -}}
{{- end -}}
{{- join "," $endpoints -}}
{{- end -}}

{{/*
Return the storage class name
*/}}
{{- define "etcd.storageClass" -}}
{{- if .Values.persistence.storageClass -}}
  {{- if (eq "-" .Values.persistence.storageClass) -}}
    {{- printf "storageClassName: \"\"" -}}
  {{- else }}
    {{- printf "storageClassName: %s" .Values.persistence.storageClass -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return image pull secrets
*/}}
{{- define "etcd.imagePullSecrets" -}}
{{- $pullSecrets := list }}
{{- if .Values.global }}
  {{- range .Values.global.imagePullSecrets }}
    {{- $pullSecrets = append $pullSecrets . }}
  {{- end }}
{{- end }}
{{- range .Values.image.pullSecrets }}
  {{- $pullSecrets = append $pullSecrets . }}
{{- end }}
{{- if $pullSecrets }}
imagePullSecrets:
  {{- range $pullSecrets }}
  - name: {{ . }}
  {{- end }}
{{- end }}
{{- end -}}
