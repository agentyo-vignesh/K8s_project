{{/*
Shared template helpers.

Naming follows the Helm convention: <release>-<chart>-<component>, truncated to
63 characters because that is the Kubernetes limit for a label value and for most
resource names.
*/}}

{{- define "aip.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "aip.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Per-component resource name, e.g. release-ai-interview-platform-middleware. */}}
{{- define "aip.componentName" -}}
{{- printf "%s-%s" (include "aip.fullname" .root) .component | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "aip.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Labels applied to every object. `version` and `managed-by` change on each upgrade,
so they must not appear in selectors.
*/}}
{{- define "aip.labels" -}}
helm.sh/chart: {{ include "aip.chart" . }}
app.kubernetes.io/name: {{ include "aip.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: ai-interview-platform
environment: {{ .Values.environment }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Selector labels: immutable for the life of a Deployment.

A Deployment's .spec.selector is immutable in the API, so anything that changes
between releases (chart version, app version) must be excluded or the next
upgrade fails with "field is immutable".
*/}}
{{- define "aip.selectorLabels" -}}
app.kubernetes.io/name: {{ include "aip.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "aip.componentLabels" -}}
{{ include "aip.labels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
Fully-qualified image reference.

global.imageRegistry is prefixed when set, so promoting from a local build to ECR
is a single value rather than an edit in three places.
*/}}
{{- define "aip.image" -}}
{{- $registry := .root.Values.global.imageRegistry -}}
{{- $tag := default .root.Chart.AppVersion .image.tag -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" (trimSuffix "/" $registry) .image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .image.repository $tag -}}
{{- end -}}
{{- end -}}

{{/* Name of the Secret holding credentials: either one we render or one supplied. */}}
{{- define "aip.secretName" -}}
{{- if .Values.secrets.existingSecret -}}
{{- .Values.secrets.existingSecret -}}
{{- else -}}
{{- printf "%s-secrets" (include "aip.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "aip.middlewareServiceAccountName" -}}
{{- if .Values.middleware.serviceAccount.create -}}
{{- default (printf "%s-middleware" (include "aip.fullname" .)) .Values.middleware.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.middleware.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "aip.aiServiceAccountName" -}}
{{- if .Values.aiService.serviceAccount.create -}}
{{- default (printf "%s-ai-service" (include "aip.fullname" .)) .Values.aiService.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.aiService.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Database host.

In-cluster PostgreSQL resolves through its headless Service; otherwise the
external host is used. With Secrets Manager enabled neither is consulted: the
services read host, port and database name from the secret payload so the parts
cannot come from two different sources and disagree.
*/}}
{{- define "aip.databaseHost" -}}
{{- if .Values.postgresql.enabled -}}
{{- printf "%s-postgresql" (include "aip.fullname" .) -}}
{{- else -}}
{{- required "postgresql.external.host is required when postgresql.enabled=false and AWS Secrets Manager is disabled" .Values.postgresql.external.host -}}
{{- end -}}
{{- end -}}

{{- define "aip.databasePort" -}}
{{- if .Values.postgresql.enabled -}}
{{- .Values.postgresql.service.port -}}
{{- else -}}
{{- .Values.postgresql.external.port -}}
{{- end -}}
{{- end -}}

{{- define "aip.databaseName" -}}
{{- if .Values.postgresql.enabled -}}
{{- .Values.postgresql.auth.database -}}
{{- else -}}
{{- .Values.postgresql.external.database -}}
{{- end -}}
{{- end -}}

{{- define "aip.databaseUsername" -}}
{{- if .Values.postgresql.enabled -}}
{{- .Values.postgresql.auth.username -}}
{{- else -}}
{{- .Values.postgresql.external.username -}}
{{- end -}}
{{- end -}}

{{- define "aip.databaseSslMode" -}}
{{- if .Values.postgresql.enabled -}}
{{- "prefer" -}}
{{- else -}}
{{- .Values.postgresql.external.sslMode -}}
{{- end -}}
{{- end -}}

{{/* Spring profile derived from the environment so there is one thing to set. */}}
{{- define "aip.springProfile" -}}
{{- if eq .Values.environment "dev" -}}dev{{- else if eq .Values.environment "staging" -}}prod{{- else -}}prod{{- end -}}
{{- end -}}

{{- define "aip.middlewareServiceHost" -}}
{{- printf "%s-middleware" (include "aip.fullname" .) -}}
{{- end -}}

{{- define "aip.aiServiceHost" -}}
{{- printf "%s-ai-service" (include "aip.fullname" .) -}}
{{- end -}}

{{- define "aip.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{ toYaml . }}
{{- end }}
{{- end -}}
