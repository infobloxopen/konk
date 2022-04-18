{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "konk-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "konk-service.fullname" -}}
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
{{- define "konk-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "konk-service.labels" -}}
helm.sh/chart: {{ include "konk-service.chart" . }}
{{ include "konk-service.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "konk-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "konk-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "konk-service.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "konk-service.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Big thanks to opa chart for this!
https://github.com/helm/charts/blob/master/stable/opa/templates/_helpers.tpl#L85
Detect the version of cert manager crd that is installed
Error if CRD is not available
*/}}
{{- define "konk-service.certManagerApiVersion" -}}
{{- if (.Capabilities.APIVersions.Has "cert-manager.io/v1") -}}
cert-manager.io/v1
{{- else if (.Capabilities.APIVersions.Has "cert-manager.io/v1beta1") -}}
cert-manager.io/v1beta1
{{- else if (.Capabilities.APIVersions.Has "cert-manager.io/v1alpha3") -}}
cert-manager.io/v1alpha3
{{- else if (.Capabilities.APIVersions.Has "cert-manager.io/v1alpha2") -}}
cert-manager.io/v1alpha2
{{- else if .Values.isLint -}}
dummy
{{- else  -}}
{{- fail "cert-manager CRD does not appear to be installed" }}
{{- end -}}
{{- end -}}

{{/*
Templates konk name
*/}}
{{- define "konk-service.konkname" -}}
{{- .Values.konk.name }}
{{- end }}

{{- define "konk-service.konkfqdn" -}}
{{- .Values.konk.name -}}
{{- if .Values.konk.namespace -}}
.{{- .Values.konk.namespace -}}.svc
{{- end }}
{{- end }}
