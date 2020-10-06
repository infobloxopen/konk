{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "api-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "api-service.fullname" -}}
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
{{- define "api-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "api-service.labels" -}}
helm.sh/chart: {{ include "api-service.chart" . }}
{{ include "api-service.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "api-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "api-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "api-service.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "api-service.fullname" .) .Values.serviceAccount.name }}
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
{{- define "api-service.certManagerApiVersion" -}}
{{- if (.Capabilities.APIVersions.Has "cert-manager.io/v1alpha3") -}}
cert-manager.io/v1alpha3
{{- else if (.Capabilities.APIVersions.Has "cert-manager.io/v1alpha2") -}}
cert-manager.io/v1alpha2
{{- else if (.Capabilities.APIVersions.Has "certmanager.k8s.io/v1alpha1") -}}
certmanager.k8s.io/v1alpha1
{{- else  -}}
{{- fail "cert-manager CRD does not appear to be installed" }}
{{- end -}}
{{- end -}}
