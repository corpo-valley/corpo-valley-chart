#!/usr/bin/env bash
# Post-`helm install` one-shot bootstrap for the bits the chart can't model
# cleanly (they mutate state inside Gitea rather than declare k8s resources):
#
#  1. Create the cvportal Gitea site-admin user + access token; patch the
#     gitea-admin Secret and restart the portal so it picks the token up.
#  2. Register the "CorpoValley" OIDC auth source in Gitea (login via Hydra).
#  3. Mint a Gitea Actions runner registration token; patch the
#     runner-registration-token Secret and restart the runner.
#  4. Give the projects ArgoCD a Gitea repo credential so it can CLONE the
#     (always-private) project repos — without it, every project Application
#     fails to sync (there is no anonymous fallback now that repos are private).
#  5. If a platform ArgoCD is present in `argocd`, set
#     ARGOCD_GIT_MODULES_ENABLED=false on argocd-repo-server (skip submodules).
#
# Idempotent: every step checks current state first and skips if already done.
#
# Usage:
#   ./post-install.sh --domain example.com [--namespace-prefix cv-]
#
# Requires: kubectl pointed at the cluster the chart was installed into.

set -euo pipefail

DOMAIN=""
NSP="cv-"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)           DOMAIN="$2"; shift 2 ;;
    --namespace-prefix) NSP="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | head -n -1 | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$DOMAIN" ]] || { echo "ERROR: --domain is required (see --help)" >&2; exit 1; }

PORTAL_NS="${NSP}portal"
GITEA_NS="${NSP}gitea"
ORY_NS="${NSP}ory"
RUNNERS_NS="${NSP}gitea-runners"
OAUTH_HOST="oauth.${DOMAIN}"

GITEA_POD=$(kubectl -n "$GITEA_NS" get pod -l app=gitea -o jsonpath='{.items[0].metadata.name}')
gitea_cli() { kubectl -n "$GITEA_NS" exec "$GITEA_POD" -- su gitea -c "$*"; }

# 1. cvportal site-admin + token
echo "==> cvportal site-admin"
if ! gitea_cli 'gitea admin user list' | awk '{print $2}' | grep -qx cvportal; then
  CVPORTAL_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
  gitea_cli "gitea admin user create --username cvportal --password '$CVPORTAL_PASSWORD' --email cvportal@${DOMAIN} --admin --must-change-password=false"
  echo "    created cvportal (password not stored — only the token matters)"
fi

EXISTING_TOKEN=$(kubectl -n "$PORTAL_NS" get secret gitea-admin -o jsonpath='{.data.GITEA_ADMIN_TOKEN}' 2>/dev/null | base64 -d || true)
if [[ -z "$EXISTING_TOKEN" || "$EXISTING_TOKEN" == "unset-mint-post-install" ]]; then
  TOKEN=$(gitea_cli "gitea admin user generate-access-token --username cvportal --token-name corpo-valley-portal --scopes all" | awk -F': ' '/Access token/ {print $2}')
  [[ -n "$TOKEN" ]] || { echo "ERROR: token mint failed — re-run, or seed gitea-admin manually" >&2; exit 1; }
  kubectl -n "$PORTAL_NS" patch secret gitea-admin --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/data/GITEA_ADMIN_TOKEN\",\"value\":\"$(printf '%s' "$TOKEN" | base64 -w0)\"}]"
  kubectl -n "$PORTAL_NS" rollout restart deploy/portal
  echo "    minted + applied cvportal token"
fi

# 2. CorpoValley OIDC auth source
echo "==> CorpoValley OIDC auth source"
if ! gitea_cli 'gitea admin auth list' | grep -q CorpoValley; then
  HYDRA_GITEA_SECRET=$(kubectl -n "$ORY_NS" get secret ory-hydra-clients -o jsonpath='{.data.GITEA_CLIENT_SECRET}' | base64 -d)
  gitea_cli "gitea admin auth add-oauth \
    --name CorpoValley \
    --provider openidConnect \
    --key gitea \
    --secret '$HYDRA_GITEA_SECRET' \
    --auto-discover-url 'https://${OAUTH_HOST}/.well-known/openid-configuration' \
    --skip-local-2fa"
  echo "    added CorpoValley auth source"
fi

# 3. Actions runner registration token
echo "==> runner registration token"
EXISTING_RUNNER_TOKEN=$(kubectl -n "$RUNNERS_NS" get secret runner-registration-token -o jsonpath='{.data.GITEA_RUNNER_REGISTRATION_TOKEN}' 2>/dev/null | base64 -d || true)
if [[ -z "$EXISTING_RUNNER_TOKEN" || "$EXISTING_RUNNER_TOKEN" == "unset-mint-post-install" ]]; then
  RUNNER_TOKEN=$(gitea_cli "gitea actions generate-runner-token" | tr -d '[:space:]')
  [[ -n "$RUNNER_TOKEN" ]] || { echo "ERROR: runner token mint failed" >&2; exit 1; }
  kubectl -n "$RUNNERS_NS" patch secret runner-registration-token --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/data/GITEA_RUNNER_REGISTRATION_TOKEN\",\"value\":\"$(printf '%s' "$RUNNER_TOKEN" | base64 -w0)\"}]"
  kubectl -n "$RUNNERS_NS" rollout restart statefulset/gitea-runner
  echo "    minted + applied runner registration token"
fi

# 4. projects-argocd → Gitea repo credential. The projects ArgoCD clones tenant
#    repos over the in-cluster Gitea Service; those repos are ALWAYS private, so
#    without a credential every project Application fails to sync (no anonymous
#    fallback). This is an ArgoCD repo-creds template keyed by URL prefix, so one
#    secret covers every project repo. Least privilege: a dedicated
#    read:repository token on cvportal, not the all-scopes admin token. Skipped
#    if the secret already exists (don't clobber a working credential).
echo "==> projects-argocd Gitea repo credential"
PROJECTS_ARGOCD_NS="${NSP}projects-argocd"
GITEA_INTERNAL_URL="http://gitea.${GITEA_NS}.svc.cluster.local/"
if ! kubectl get ns "$PROJECTS_ARGOCD_NS" >/dev/null 2>&1; then
  echo "    namespace ${PROJECTS_ARGOCD_NS} absent — install the projects ArgoCD first, then re-run"
elif kubectl -n "$PROJECTS_ARGOCD_NS" get secret projects-argocd-gitea-repocreds >/dev/null 2>&1; then
  echo "    already present — skipped"
else
  ARGOCD_TOKEN=$(gitea_cli "gitea admin user generate-access-token --username cvportal --token-name corpo-valley-argocd-read --scopes read:repository" | awk -F': ' '/Access token/ {print $2}')
  [[ -n "$ARGOCD_TOKEN" ]] || { echo "ERROR: argocd repo token mint failed (a token named corpo-valley-argocd-read may already exist on cvportal — delete it in Gitea, then re-run)" >&2; exit 1; }
  kubectl apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: projects-argocd-gitea-repocreds
  namespace: ${PROJECTS_ARGOCD_NS}
  labels:
    argocd.argoproj.io/secret-type: repo-creds
type: Opaque
stringData:
  type: git
  url: ${GITEA_INTERNAL_URL}
  username: cvportal
  password: ${ARGOCD_TOKEN}
YAML
  echo "    created projects-argocd-gitea-repocreds (covers ${GITEA_INTERNAL_URL})"
fi

# 5. ARGOCD_GIT_MODULES_ENABLED=false (only when a platform ArgoCD exists)
echo "==> argocd-repo-server submodule init"
if kubectl -n argocd get deploy argocd-repo-server >/dev/null 2>&1; then
  CURRENT=$(kubectl -n argocd get deploy argocd-repo-server -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ARGOCD_GIT_MODULES_ENABLED")].value}')
  if [[ "$CURRENT" != "false" ]]; then
    kubectl -n argocd set env deploy/argocd-repo-server ARGOCD_GIT_MODULES_ENABLED=false
    echo "    set ARGOCD_GIT_MODULES_ENABLED=false"
  fi
else
  echo "    no platform ArgoCD in 'argocd' — skipped"
fi

echo
echo "Post-install complete. Next steps:"
echo "  - scripts/setup-node-registry.sh on EVERY node (kubelet -> cv-registry pulls)"
echo "  - scripts/bootstrap-admin.sh --email you@... --username you"
