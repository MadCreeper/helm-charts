{{- define "catalog-mirror.name" -}}{{ default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}{{- end -}}
{{- define "catalog-mirror.fullname" -}}
{{- if .Values.fullnameOverride -}}{{ .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else -}}{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}{{ .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else -}}{{ printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}{{- end -}}{{- end -}}
{{- end -}}
{{- define "catalog-mirror.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "catalog-mirror.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
{{- define "catalog-mirror.selectorLabels" -}}
app.kubernetes.io/name: {{ include "catalog-mirror.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
{{- define "catalog-mirror.claimName" -}}{{ .Values.persistence.existingClaim | default (printf "%s-data" (include "catalog-mirror.fullname" .)) }}{{- end -}}
{{/* In-cluster base URL, as swiss would be configured with it. */}}
{{- define "catalog-mirror.url" -}}
{{- printf "http://%s.%s.svc" (include "catalog-mirror.fullname" .) .Release.Namespace -}}{{ if ne (int .Values.service.port) 80 }}:{{ .Values.service.port }}{{ end }}
{{- end -}}
