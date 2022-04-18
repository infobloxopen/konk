{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "konk.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "konk.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
    {{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
    {{- else }}
        {{- if hasSuffix "-konk" .Release.Name }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
        {{- else if (eq "RELEASE-NAME" .Release.Name) }}
{{- "template-konk" }}
        {{- else if (eq "testRelease" .Release.Name) }}
{{- "lint-konk" }}
        {{- else }}
{{- fail (printf "release name (%s) must include a -konk suffix:" .Release.Name) }}
        {{- end }}
    {{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "konk.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "konk.labels" -}}
helm.sh/chart: {{ include "konk.chart" . }}
{{ include "konk.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "konk.selectorLabels" -}}
app.kubernetes.io/name: {{ include "konk.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "konk.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "konk.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Prefixes "Cluster" when Konk is cluster-scoped
*/}}
{{- define "konk.scope" -}}
{{- if eq "cluster" .Values.scope -}}
{{- if not .Values.certManager.namespace }}
{{ fail ".certManager.namespace is required for cluster-scoped konks" }}
{{- end -}}
Cluster
{{- end }}
{{- end }}

{{/*
Big thanks to opa chart for this!
https://github.com/helm/charts/blob/master/stable/opa/templates/_helpers.tpl#L85
Detect the version of cert manager crd that is installed
Error if CRD is not available
*/}}
{{- define "konk.certManagerApiVersion" -}}
{{- if (.Capabilities.APIVersions.Has "cert-manager.io/v1") -}}
cert-manager.io/v1
{{- else if (.Capabilities.APIVersions.Has "cert-manager.io/v1beta1") -}}
cert-manager.io/v1beta1
{{- else if (.Capabilities.APIVersions.Has "cert-manager.io/v1alpha3") -}}
cert-manager.io/v1alpha3
{{- else if (.Capabilities.APIVersions.Has "cert-manager.io/v1alpha2") -}}
cert-manager.io/v1alpha2
{{- else if (.Capabilities.APIVersions.Has "certmanager.k8s.io/v1alpha1") -}}
certmanager.k8s.io/v1alpha1
{{- else if .Values.isLint -}}
dummy
{{- else  -}}
{{- fail "cert-manager CRD does not appear to be installed" }}
{{- end -}}
{{- end -}}
