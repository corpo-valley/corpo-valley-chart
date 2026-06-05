# corpo-valley Helm chart

Helm chart for the Corpo Valley platform — a single-tenant monorepo platform
that abstracts code + infra so non-technical users can drive Claude Code
safely. The application source and per-component Dockerfiles live in
[corpo-valley/corpo-valley-main](https://github.com/corpo-valley/corpo-valley-main);
images publish to `ghcr.io/corpo-valley/corpo-valley-*` (public). This chart
packages the platform's Kubernetes manifests so a fresh cluster can be
brought up with a single `helm install` and a value file.

The chart renders 90+ resources: the Ory stack (Postgres, Kratos, Hydra, Keto,
Oathkeeper), the portal + MCP gateway, Gitea + Actions runner, cv-registry, the
Cloudflare tunnel, the per-project AppProject + ValidatingAdmissionPolicies,
and the platform NetworkPolicies.

## Status

Phase 1. The chart targets `role: all-in-one` — one cluster, one platform
instance. `role: platform` / `role: tenants` are scaffolded for a future
platform/tenants cluster split but are not fully wired yet.

## Quick start

Assumes a fresh cluster with:

- An nginx ingress controller in namespace `ingress` (or override
  `ingress.className`)
- A bitnami sealed-secrets controller in `kube-system`
- A platform ArgoCD in `argocd` (optional if applying via plain
  `kubectl apply`; required if you want GitOps reconciliation)
- A projects ArgoCD in `cv-projects-argocd` (or whatever
  `argocd.projectsArgocd.nsLogical` you set)

The companion repo
[corpo-valley-hetzner](https://github.com/hashtagcyber/corpo-valley-hetzner)
provisions those prereqs on a 2-VM Hetzner cluster and runs the full install
end-to-end. The rest of this README explains the chart itself.

```bash
# 1. Provision the secrets the chart references (see SEALED_SECRETS.md).
./scripts/generate-secrets.sh \
  --namespace-prefix cv- \
  --smtp-uri 'smtps://USER:PASS@smtp.example.com:465/' \
  --cloudflare-credentials ./tunnel-credentials.json \
  --seal --output ./out/secrets

kubectl apply -f ./out/secrets/sealed/

# 2. Install the chart.
helm install corpo-valley . \
  --set domain=corpo-valley.com \
  --set cloudflare.tunnelId=eb36fca0-1f28-4556-b313-f2d823e7cff2 \
  -f values.example.yaml

# 3. Post-install (one-shot, not chart-managed):
#    - Create the cvportal Gitea site-admin user + token.
#    - Register the "CorpoValley" Gitea OIDC auth source.
#    - Patch argocd-repo-server: ARGOCD_GIT_MODULES_ENABLED=false.
#    The hetzner repo's bootstrap.sh handles all three idempotently.
```

## Configuration

Every setting is overridable via `values.yaml`. Defaults reproduce the
current `corpo-valley.com` deployment.

| Key | Default | What it does |
|---|---|---|
| `role` | `all-in-one` | Phase-1 mode (the only one fully rendered). |
| `domain` | `corpo-valley.com` | Base domain. All `hosts.*` default to `<sub>.<domain>`. |
| `hosts.portal` | derived | Override only if the portal lives at a non-`portal.<domain>` host. |
| `hosts.projectsWildcard` | `*.projects.<domain>` | Wildcard the projects ArgoCD's Ingresses live under. |
| `hosts.oathkeeperWildcard` | `true` | Whether Oathkeeper publishes the `*.<domain>` Ingress. |
| `namespacePrefix` | `cv-` | Prefix for every platform namespace. Set to `acme-` etc. to coexist. |
| `image.registry` | `ghcr.io/corpo-valley` | Container image registry. |
| `image.prefix` | `corpo-valley-` | Concatenated with the component name. |
| `image.tags.<component>` | `latest` | Per-component tag override. |
| `image.pullSecret` | `ghcr-pull-secret` | imagePullSecret name; the chart does not create it. Only needed if your registry is private. |
| `git.platformRepoUrl` | corpo-valley-hetzner.git | What the `corpo-valley` AppProject scopes child Applications to (the deployment repo). |
| `cloudflare.tunnelId` | *(required)* | UUID from `cloudflared tunnel create`. |
| `cloudflare.tunnelName` | `corpo-valley-cluster` | Cosmetic. |
| `email.fromAddress` | `noreply@dev.cobl.io` | Kratos courier visible "from" address. |
| `storage.className` | `""` (cluster default) | Set to `hcloud-volumes` on Hetzner, `microk8s-hostpath` for microk8s. |
| `storage.oryPostgres` / `gitea` / `registry` | `5Gi` / `10Gi` / `50Gi` | Per-PVC sizes. |
| `cluster.podCIDR` / `serviceCIDR` / `nodeCIDR` | matches the live deploy | Used by the per-project egress NetworkPolicies emitted by the portal. |
| `cluster.sealedSecretsControllerUrl` | in-cluster default | The portal fetches the public cert from here to seal project secrets. |
| `resources.<component>.requests` / `limits` | matches the live deploy | Per-component resources. |
| `giteaRunner.replicas` | `1` | Bump for build concurrency. |
| `argocd.projectsArgocd.enabled` / `nsLogical` / `appProject` | `true` / `projects-argocd` / `projects` | The projects-ArgoCD wiring the chart expects. |
| `argocd.trustedClientIds` | `argocd,gitea` | Hydra clients that bypass the consent screen. |
| `mcp.publicUrl` | `https://<hosts.mcp>` | What RFC 9728 protected-resource metadata announces. |

See `values.schema.json` for the full constrained schema. `helm install`
validates inputs against it.

## What the chart does NOT install

These have to exist before `helm install`:

- The platform ArgoCD (in `argocd` namespace). The chart's `corpo-valley`
  AppProject expects it; without it the AppProject is harmless.
- The projects ArgoCD (in `cv-projects-argocd` namespace). The chart's
  `projects` AppProject expects it. Install upstream `namespace-install.yaml`
  per [argo-cd docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/installation/#non-high-availability)
  into the configured namespace.
- The sealed-secrets controller (in `kube-system`).
- The nginx ingress controller (in `ingress`).

These have to be done after `helm install`:

- `cvportal` Gitea site-admin user + token (Gitea CLI).
- `CorpoValley` Gitea OIDC auth source (Gitea CLI).
- `ARGOCD_GIT_MODULES_ENABLED=false` on `argocd-repo-server` (only if you use
  submodules elsewhere and want ArgoCD to skip them).
- Node-side registry routing (`/etc/hosts` + containerd certs.d) so kubelet
  can pull from `cv-registry`. The hetzner repo ships a `setup-node-registry.sh`.

The `corpo-valley-hetzner` repo runs all of these in `bootstrap.sh`.

## Verifying

```bash
# Schema + template:
helm lint .
helm template test . --set cloudflare.tunnelId=test-uuid >/tmp/cv.yaml

# Validate as YAML / k8s schema (requires kubeconform):
kubeconform -strict -summary -ignore-missing-schemas /tmp/cv.yaml

# Diff against a live cluster:
helm diff upgrade corpo-valley . -f your-values.yaml
```

## Layout

```
Chart.yaml              # chart metadata + version
values.yaml             # defaults
values.schema.json      # validated by helm install
templates/
  _helpers.tpl          # cv.ns, cv.host, cv.image, cv.svc, cv.labels
  00-namespaces.yaml    # every cv-* namespace
  10-ory-*.yaml         # Ory stack (postgres / kratos / hydra / keto / oathkeeper)
  20-portal.yaml        # portal Deployment + RBAC + Ingresses (incl. MCP)
  21-mcp-gateway.yaml   # MCP-gateway sidecar Deployment + NetworkPolicies
  30-gitea.yaml         # gitea Deployment + PVC
  31-gitea-oidc.yaml    # PostSync hooks: hydra client + keto BETA grant
  32-gitea-runners.yaml # act_runner + dind + egress NetworkPolicy
  40-registry.yaml      # cv-registry
  50-cloudflared.yaml   # cloudflare-tunnel Deployment + config
  60-appprojects.yaml   # AppProject "corpo-valley" + AppProject "projects"
  61-cv-projects-policies.yaml          # 5 VAPs that fence project ArgoCD writes
  62-cv-projects-pod-bounds.yaml        # pod-security VAP
  63-cv-projects-postgres-bounds.yaml   # per-project Postgres VAP
  64-cv-platform-portal-bounds.yaml     # portal SA PVC-delete fence
  65-cv-platform-netpols.yaml           # ingress NetworkPolicies on platform svcs
scripts/
  generate-secrets.sh   # mints + optionally seals every Secret the chart needs
values.example.yaml     # an anonymized template you can copy
values.corpo-valley.yaml # the values for the current corpo-valley.com deploy
SEALED_SECRETS.md       # what secrets to provision, with what keys
```
