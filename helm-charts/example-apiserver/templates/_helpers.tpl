{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "example-apiserver.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "example-apiserver.fullname" -}}
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
{{- define "example-apiserver.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "example-apiserver.labels" -}}
helm.sh/chart: {{ include "example-apiserver.chart" . }}
{{ include "example-apiserver.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "example-apiserver.selectorLabels" -}}
app.kubernetes.io/name: {{ include "example-apiserver.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "example-apiserver.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "example-apiserver.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
    Templates konk name
*/}}
{{- define "example-apiserver.konkname" -}}
{{- .Values.konk.name | default (printf "%s-konk" .Release.Name) }}
{{- end }}

{{/*
    Template konk namespace
*/}}
{{- define "example-apiserver.konknamespace" -}}
{{- .Values.konk.namespace | default .Release.Namespace }}
{{- end }}


{{/*
Templates konk-service name
*/}}
{{- define "example-apiserver.konk-service-name" -}}
{{- .Values.konkservice.name | default (printf "%s-konk-service" .Release.Name) }}
{{- end }}

{{/*
Templates konk-service namespace
*/}}
{{- define "example-apiserver.konk-service-namespace" -}}
{{- .Values.konkservice.namespace | default .Release.Namespace }}
{{- end }}
