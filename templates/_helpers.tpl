{{/*
  ----------------------------------------------------------------------------
  Corpo Valley helpers.

  Calling convention: every helper takes the root context as the FIRST argument
  so it works correctly inside `range` and nested scopes. Example:

    namespace: {{ include "cv.ns" (list $ "ory") }}
    host:      {{ include "cv.host" (list $ "portal") }}
    image:     {{ include "cv.image" (list $ "portal") }}
    svc:       {{ include "cv.svc" (list $ "ory-kratos-public" "ory") }}

  Keeping the convention strict makes the templates grep-able and avoids the
  classic "works at top level, breaks in range" Helm trap.
  ----------------------------------------------------------------------------
*/}}

{{/* Full namespace from prefix + logical name. */}}
{{- define "cv.ns" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- printf "%s%s" $root.Values.namespacePrefix $name -}}
{{- end -}}

{{/* Public host. Resolves to the explicit hosts.<name> override if set,
     otherwise to <name>.<domain>. */}}
{{- define "cv.host" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- $override := index $root.Values.hosts $name | default "" -}}
{{- if $override -}}
{{- $override -}}
{{- else -}}
{{- printf "%s.%s" $name $root.Values.domain -}}
{{- end -}}
{{- end -}}

{{/* Wildcard host for the projects subdomain (used by Cloudflare DNS + VAPs).
     Defaults to "*.projects.<domain>", overridable via hosts.projectsWildcard. */}}
{{- define "cv.projectsWildcard" -}}
{{- $root := . -}}
{{- $override := $root.Values.hosts.projectsWildcard | default "" -}}
{{- if $override -}}
{{- $override -}}
{{- else -}}
{{- printf "*.projects.%s" $root.Values.domain -}}
{{- end -}}
{{- end -}}

{{/* The host pattern that VAP CEL expressions match against project Ingresses.
     This is the projectsWildcard with "*" replaced by the namespace match,
     used inside string concatenation in CEL. */}}
{{- define "cv.projectsHostSuffix" -}}
{{- $root := . -}}
{{- $w := include "cv.projectsWildcard" $root -}}
{{- trimPrefix "*." $w -}}
{{- end -}}

{{/* Cookie / CORS allowed-origin wildcard. */}}
{{- define "cv.corsWildcard" -}}
{{- $root := . -}}
{{- printf "https://*.%s" $root.Values.domain -}}
{{- end -}}

{{/* Image ref for a platform component.
     <image.registry>/<image.prefix><name>:<tag>
     Default registry produces ghcr.io/corpo-valley/corpo-valley-<name>:<tag>.
     Tag resolves to image.tags.<name> if set, else image.defaultTag. */}}
{{- define "cv.image" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- $tag := index $root.Values.image.tags $name | default $root.Values.image.defaultTag -}}
{{- printf "%s/%s%s:%s" $root.Values.image.registry $root.Values.image.prefix $name $tag -}}
{{- end -}}

{{/* In-cluster service FQDN: <svc>.<ns>.svc.cluster.local */}}
{{- define "cv.svc" -}}
{{- $root := index . 0 -}}
{{- $svc := index . 1 -}}
{{- $nsLogical := index . 2 -}}
{{- printf "%s.%s%s.svc.cluster.local" $svc $root.Values.namespacePrefix $nsLogical -}}
{{- end -}}

{{/* Common labels applied to every chart-managed resource. */}}
{{- define "cv.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: corpo-valley-platform
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* Whether the current role renders the platform tier (Ory/portal/gitea/etc.) */}}
{{- define "cv.role.platform" -}}
{{- $r := .Values.role -}}
{{- if or (eq $r "all-in-one") (eq $r "platform") -}}true{{- end -}}
{{- end -}}

{{/* Whether the current role renders the tenants tier (per-project VAPs etc.) */}}
{{- define "cv.role.tenants" -}}
{{- $r := .Values.role -}}
{{- if or (eq $r "all-in-one") (eq $r "tenants") -}}true{{- end -}}
{{- end -}}
