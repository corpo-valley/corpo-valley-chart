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

{{/*
  Admission bounds for ONE per-project stateful capability (Postgres, Garage, …).
  Both per-capability VAPs were ~90% identical; this is the single source so a
  new capability is one call, not a copied 60-line file. Caller passes a dict:
    ctx          – the root context ($)
    name         – capability name == the corpo-valley.com/managed label value
                   (also the VAP name suffix); title-cased in messages.
    image        – the single pinned image the StatefulSet's container must use.
    maxPerVolume – the per-PVC storage ceiling (tenant.storage.maxPerVolume).
  Emits the ValidatingAdmissionPolicy + binding. Fires only on StatefulSets the
  projects-argocd controller creates that carry the managed=<name> label.
*/}}
{{- define "cv.capabilityBounds" -}}
{{- $ctx := .ctx -}}
{{- $name := .name -}}
{{- $image := .image -}}
{{- $maxPerVolume := .maxPerVolume -}}
{{- $display := title $name -}}
{{- $projectsArgocdNs := include "cv.ns" (list $ctx $ctx.Values.argocd.projectsArgocd.nsLogical) -}}
{{- $controllerSa := printf "system:serviceaccount:%s:argocd-application-controller" $projectsArgocdNs -}}
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: cv-projects-{{ $name }}-bounds
  labels:
    {{- include "cv.labels" $ctx | nindent 4 }}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["statefulsets"]
  matchConditions:
    - name: only-projects-argocd-controller
      expression: "request.userInfo.username == '{{ $controllerSa }}'"
    - name: only-managed-{{ $name }}
      expression: "has(object.metadata.labels) && 'corpo-valley.com/managed' in object.metadata.labels && object.metadata.labels['corpo-valley.com/managed'] == '{{ $name }}'"
  validations:
    - expression: "has(object.spec.replicas) && object.spec.replicas == 1"
      message: "Project-managed {{ $display }} must have replicas: 1 (HA not supported on this tier)."
    - expression: "object.spec.template.spec.containers.size() == 1"
      message: "Project-managed {{ $display }} pod must have exactly one container (no sidecars on this tier)."
    - expression: "object.spec.template.spec.containers.all(c, c.image == '{{ $image }}')"
      message: "Project-managed {{ $display }} image must be {{ $image }} (image pinning gate)."
    - expression: "object.spec.template.spec.containers.all(c, !has(c.securityContext) || !has(c.securityContext.privileged) || c.securityContext.privileged == false)"
      message: "Project-managed {{ $display }} containers must not be privileged."
    - expression: "object.spec.template.spec.containers.all(c, !has(c.securityContext) || !has(c.securityContext.allowPrivilegeEscalation) || c.securityContext.allowPrivilegeEscalation == false)"
      message: "Project-managed {{ $display }} containers must not allowPrivilegeEscalation."
    - expression: "has(object.spec.template.spec.securityContext) && has(object.spec.template.spec.securityContext.runAsNonRoot) && object.spec.template.spec.securityContext.runAsNonRoot == true"
      message: "Project-managed {{ $display }} must set pod securityContext.runAsNonRoot=true."
    - expression: "object.spec.template.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.capabilities) && has(c.securityContext.capabilities.drop) && c.securityContext.capabilities.drop.exists(d, d == 'ALL'))"
      message: "Project-managed {{ $display }} containers must drop ALL capabilities."
    - expression: "!has(object.spec.template.spec.hostNetwork) || object.spec.template.spec.hostNetwork == false"
      message: "Project-managed {{ $display }} must not use hostNetwork."
    - expression: "!has(object.spec.template.spec.hostPID) || object.spec.template.spec.hostPID == false"
      message: "Project-managed {{ $display }} must not use hostPID."
    - expression: "!has(object.spec.template.spec.hostIPC) || object.spec.template.spec.hostIPC == false"
      message: "Project-managed {{ $display }} must not use hostIPC."
    - expression: "!has(object.spec.template.spec.volumes) || object.spec.template.spec.volumes.all(v, !has(v.hostPath))"
      message: "Project-managed {{ $display }} must not mount hostPath volumes."
    - expression: "object.spec.volumeClaimTemplates.all(t, !quantity(t.spec.resources.requests.storage).isGreaterThan(quantity('{{ $maxPerVolume }}')))"
      message: "Project-managed {{ $display }} storage must be <= {{ $maxPerVolume }} (per-volume cap)."
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: cv-projects-{{ $name }}-bounds
  labels:
    {{- include "cv.labels" $ctx | nindent 4 }}
spec:
  policyName: cv-projects-{{ $name }}-bounds
  validationActions: [Deny]
{{- end -}}
