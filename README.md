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

## Install — from a deployed cluster to a running Corpo Valley

Start point: a working Kubernetes cluster (any distro; microk8s and k3s are
the tested ones) with a default-able RWO storage class, plus on your
workstation: `kubectl`, `helm`, `kubeseal`, `cloudflared`, `jq`, `openssl`.
You also need a domain on Cloudflare (traffic ingresses via a Cloudflare
tunnel) and SMTP credentials for account-recovery email.

### 1. Cluster prereqs (one-time)

The chart deploys only Corpo Valley itself; these four things must exist
first:

```bash
# sealed-secrets controller (kube-system)
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.1/controller.yaml
kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=120s

# !! Back up the sealing master key NOW — without it your sealed secrets are
# !! unrecoverable on a rebuilt cluster. Store it encrypted, never in plain git.
kubectl get secrets -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-master.local.yaml

# nginx ingress controller, in namespace `ingress`.
# fullnameOverride=ingress makes the Service `ingress-controller`, which is
# where the chart's cloudflared config sends all tunnel traffic.
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress --create-namespace --set fullnameOverride=ingress \
  --set controller.kind=Deployment --set controller.replicaCount=2

# projects ArgoCD — a dedicated, namespace-scoped ArgoCD that deploys tenant
# projects. The chart's VAPs fence in what it may do.
kubectl create namespace cv-projects-argocd
kubectl apply -n cv-projects-argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.2.3/manifests/namespace-install.yaml

# (optional) platform ArgoCD in `argocd` — only if you want the platform
# itself GitOps-reconciled. A plain `helm install` works without it; if you
# add it, set git.platformRepoUrl in your values to your deployment repo.
```

### 2. Cloudflare tunnel + DNS

```bash
cloudflared tunnel login
cloudflared tunnel create corpo-valley   # note the UUID; keeps credentials.json
cloudflared tunnel route dns corpo-valley '*.example.com'
cloudflared tunnel route dns corpo-valley '*.projects.example.com'
```

Those two wildcards cover everything the platform serves: `portal.`, `auth.`,
`oauth.`, `gitea.`, `mcp.` and the per-project `<name>.projects.` hosts. The
chart runs cloudflared in-cluster; you only supply the tunnel UUID (values)
and `credentials.json` (secret, next step).

### 3. Generate + apply secrets

```bash
./scripts/generate-secrets.sh \
  --namespace-prefix cv- \
  --smtp-uri 'smtps://USER:PASS@smtp.example.com:465/' \
  --cloudflare-credentials ~/.cloudflared/<TUNNEL_UUID>.json \
  --seal --output ./out/secrets

kubectl apply -f ./out/secrets/sealed/
```

`SEALED_SECRETS.md` documents every secret if you'd rather provision them
another way. Keep `out/secrets/secrets.local.env` somewhere safe.

### 4. Write your values + install

```bash
cp values.example.yaml my-values.yaml
# Edit: domain, cluster CIDRs (must match your CNI!), storage.className,
# email.fromAddress — and the sealed-secrets cert pin:
./scripts/print-cert-pin.sh   # -> cluster.sealedSecretsCertSha256

helm install corpo-valley . \
  --set cloudflare.tunnelId=<TUNNEL_UUID> \
  -f my-values.yaml
```

### 5. Post-install bootstrap

```bash
# Creates the cvportal Gitea site-admin + token, registers the CorpoValley
# OIDC auth source, mints the Actions runner registration token, and patches
# the platform ArgoCD (if present). Idempotent — re-run freely.
./scripts/post-install.sh --domain example.com

# On EVERY node: lets kubelet pull project images from the in-cluster
# registry (plain-HTTP, ClusterIP-only). Detects microk8s/k3s.
sudo ./scripts/setup-node-registry.sh
```

### 6. First admin + verify

```bash
# Self-service registration is disabled by design — the first account is
# created against the Kratos admin API and granted the ADMIN tier. Prints a
# one-time recovery link to set your password.
./scripts/bootstrap-admin.sh --email you@example.com --username you
```

Open `https://portal.example.com`, finish the recovery flow, log in, and
create a project from the dashboard. When its pipeline goes green at
`https://<project>.projects.example.com`, you're running. Every further user
is created in the portal at `/admin/users`.

### The Community Center project template

Every new project is generated from the `corpo-valley/community-center` repo
in the in-cluster Gitea. The portal seeds it automatically on first startup —
after the post-install script has minted the cvportal token — from the
baseline baked into the portal image, rendered with this deployment's domain
and in-cluster DNS (no manual step). If the portal started before Gitea was
ready, just restart the portal Deployment; the seed is idempotent and only
runs when the repo is missing or empty.

From then on the Gitea repo is **admin-owned**: edit it in Gitea to change
what new projects start with. To discard admin edits and restore the factory
default, use Admin → Project Template → "Reset template to baseline" in the
portal (destructive: deletes files the baseline doesn't have). Upgrading the
portal image does NOT touch the live template — new baselines only land via
an explicit reset.

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
| `image.tags.<component>` | `v0.1.0` | Per-component tag override; defaults track the latest corpo-valley-main release. Use `latest` only to deliberately ride main. |
| `image.pullSecret` | `ghcr-pull-secret` | imagePullSecret name; the chart does not create it. Only needed if your registry is private. |
| `git.platformRepoUrl` | `""` | Optional. Your deployment repo, if you GitOps the platform — the `corpo-valley` AppProject scopes child Applications to it. Empty skips the AppProject. |
| `cloudflare.tunnelId` | *(required)* | UUID from `cloudflared tunnel create`. |
| `cloudflare.tunnelName` | `corpo-valley-cluster` | Cosmetic. |
| `email.fromAddress` | `noreply@dev.cobl.io` | Kratos courier visible "from" address. |
| `storage.className` | `""` (cluster default) | Set to `hcloud-volumes` on Hetzner, `microk8s-hostpath` for microk8s. |
| `storage.oryPostgres` / `gitea` / `registry` | `5Gi` / `10Gi` / `50Gi` | Per-PVC sizes. |
| `cluster.podCIDR` / `serviceCIDR` / `nodeCIDR` | matches the live deploy | Used by the per-project egress NetworkPolicies emitted by the portal. |
| `cluster.sealedSecretsControllerUrl` | in-cluster default | The portal fetches the public cert from here to seal project secrets. |
| `cluster.sealedSecretsCertSha256` | `""` | SPKI sha256 pin of the controller cert (`scripts/print-cert-pin.sh`). **Required** for project-secret sealing — production portal images refuse trust-on-first-use. |
| `resources.<component>.requests` / `limits` | matches the live deploy | Per-component resources. |
| `scale.giteaRunner` | `1` | Bump for build concurrency. |
| `argocd.projectsArgocd.enabled` / `nsLogical` / `appProject` | `true` / `projects-argocd` / `projects` | The projects-ArgoCD wiring the chart expects. |
| `argocd.trustedClientIds` | `argocd,gitea,claude-code-mcp` | Hydra clients that bypass the consent screen. |
| `mcp.publicUrl` | `https://<hosts.mcp>` | What RFC 9728 protected-resource metadata announces. |
| `mcp.enforceAudience` | `false` | RFC 8707 audience enforcement on MCP tokens (portal + gateway). Enable once your MCP clients send resource indicators. |

See `values.schema.json` for the full constrained schema. `helm install`
validates inputs against it.

## What the chart does NOT install

The chart renders only Corpo Valley itself. Everything around it is covered
by the install steps above:

- **Before `helm install`** (step 1): sealed-secrets controller, nginx
  ingress controller, projects ArgoCD, optional platform ArgoCD.
- **After `helm install`** (steps 5–6): `scripts/post-install.sh` (Gitea
  admin + token, OIDC auth source, runner token, ArgoCD submodule patch),
  `scripts/setup-node-registry.sh` on each node, and
  `scripts/bootstrap-admin.sh` for the first account.

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
  generate-secrets.sh     # mints + optionally seals every Secret the chart needs
  print-cert-pin.sh       # SPKI sha256 pin for cluster.sealedSecretsCertSha256
  post-install.sh         # Gitea admin/token, OIDC source, runner token, ArgoCD patch
  setup-node-registry.sh  # per-node kubelet -> cv-registry pull routing
  bootstrap-admin.sh      # creates the first platform admin (registration is disabled)
values.example.yaml     # an anonymized template you can copy
values.corpo-valley.yaml # the values for the current corpo-valley.com deploy
SEALED_SECRETS.md       # what secrets to provision, with what keys
```
