{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "konk-operator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "konk-operator.fullname" -}}
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
{{- define "konk-operator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "konk-operator.labels" -}}
helm.sh/chart: {{ include "konk-operator.chart" . }}
{{ include "konk-operator.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "konk-operator.selectorLabels" -}}
app.kubernetes.io/name: {{ include "konk-operator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "konk-operator.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "konk-operator.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}


{{/*
Resolve the repository for one image.

The mirror host is registry.host, or the ib0 platform registry when that is
empty. Given one, returns {host}/{org}/{name} — {name} being the last path
segment of the image's own repository, and the {org} segment dropped when
registry.org is empty. Given neither, returns the repository unchanged.

Usage: include "konk-operator.imageRepo" (dict "ctx" . "repo" .Values.image.repository)
*/}}
{{- define "konk-operator.imageRepo" -}}
{{- $registry := .ctx.Values.registry -}}
{{- $host := $registry.host | default .ctx.Values.global.ib0.services.registry.host -}}
{{- if $host -}}
{{- compact (list $host $registry.org (.repo | splitList "/" | last)) | join "/" -}}
{{- else -}}
{{- .repo -}}
{{- end -}}
{{- end -}}
