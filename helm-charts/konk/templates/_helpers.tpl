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
